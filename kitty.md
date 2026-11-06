# Отчёт по устранению сбоя рендеринга Kitty в виртуальной машине (virglrenderer на macOS)

> **Статус размещения отчёта:**
> - Внутри гостевой VM: `~/Downloads/kitty.md`
> - Дополнительно скопирован в общую папку хоста macOS: `/mnt/mac/kitty.md` (на Mac это папка, выбранная в настройках Try Omarchy как Shared Folder).

---

## 1. Кратко: что сломано и почему (диагноз)

### Проблема
Эмулятор терминала **Kitty** (проверено на версиях `0.49.0` и `0.50.0`) в гостевой NixOS под управлением `virgl` запускается, создаёт окно, но окно остаётся абсолютно пустым и прозрачным: все dmabuf-буферы окна заполнены нулями `(0, 0, 0, 0)`. При этом гостевая Mesa не сообщает об ошибках компиляции или линковки шейдеров (`GL_LINK_STATUS = GL_TRUE`, `glGetError() = GL_NO_ERROR`).

### Первопричина
1. Вершинные шейдеры рендеринга ячеек и отступов Kitty (`cell.vert.glsl`, строка 470: `compute_background_0(..., uint(gl_InstanceID - 0), uint(gl_VertexID - 0))` и `padding.vert.glsl`, строка 398) читают встроенную переменную `gl_InstanceID`.
2. Гостевая Mesa транслирует этот шейдер в TGSI/NIR и отправляет хостовому процессу virglrenderer.
3. Хостовый `virglrenderer` (`src/vrend/vrend_shader.c`) при генерации итогового GLSL для хоста видит использование `gl_InstanceID` и безусловно вставляет директиву:
   ```glsl
   #extension GL_ARB_draw_instanced : require
   ```
4. Хост macOS предоставляет для QEMU контекст **OpenGL 4.1 Core Profile**. В спецификации OpenGL Core Profile (начиная с GLSL 1.40 и OpenGL 3.1) инстансинг (`gl_InstanceID`) является **базовой частью стандарта ядра (core specification)**. Компилятор шейдеров Apple OpenGL Core Profile строго следует стандарту и **отвергает** расширение `GL_ARB_draw_instanced`, выдавая ошибку компиляции:
   ```text
   extension 'GL_ARB_draw_instanced' is not supported
   ```
5. В результате компиляция шейдера на хосте Mac терпит крах. В upstream virglrenderer это приводило либо к ошибке `VIRGL_ERROR_CTX_ILLEGAL_SHADER` и аварии контекста, либо к тихому сбросу вызова отрисовки (draw call). В гостевой системе окно терминала остаётся пустым `(0, 0, 0, 0)`.
6. **Почему другие терминалы работают:**
   - **Ghostty**: в try-omarchy / try-nix-os запускается с принудительной обёрткой `LIBGL_ALWAYS_SOFTWARE=1` (софтверный рендерер llvmpipe), так как требует OpenGL 4.3.
   - **Foot**, **mpv**: используют стандартные 2D-вызовы и не используют чтение `gl_InstanceID` в шейдерах.

---

## 2. Можно ли починить на Mac — да, и что именно нужно сделать

Проблема решается **полностью на стороне хоста (macOS)** в бандле приложения `Try Omarchy.app` (репозиторий `try-nix-os`), без необходимости модифицировать гостевую NixOS и без принудительного перевода Kitty на софтверный llvmpipe.

Для этого в библиотеку `virglrenderer`, собираемую приложением, необходимо применить два патча из проекта **OmacVM** (лицензия MIT, автор Gilles Goetsch):

1. **`virgl-core-instance-id.patch`**:
   - **Файл**: `src/vrend/vrend_shader.c`.
   - **Суть**: если требуемая версия GLSL хоста `ctx->glsl_ver_required >= 140` (Core Profile), отключает генерацию директивы `#extension GL_ARB_draw_instanced : require` для ключа `SHADER_REQ_INSTANCE_ID` (точно так же, как virglrenderer уже поступает с `SHADER_REQ_SAMPLER_RECT`).
   - Шейдер Kitty начинает успешно компилироваться хостовым Apple OpenGL 4.1 Core Profile.

2. **`virgl-shader-failure-skip-draws.patch`**:
   - **Файл**: `src/vrend/vrend_renderer.c`.
   - **Суть**: изоляция сбоев шейдеров. Если какой-либо шейдер не компилируется или не линкуется хостовым OpenGL, virglrenderer не убивает весь контекст гостя через `VIRGL_ERROR_CTX_ILLEGAL_SHADER`, а пропускает только те отрисовки, которые зависят от этого конкретного шейдера. Это защищает графический стек от зависаний в случае других несовместимостей.

---

## 3. Точные изменения в репозитории-форке (`try-nix-os`)

Все изменения производятся в репозитории-форке:
**`https://github.com/gosha20777/try-nix-os`** (ветка `main`).

> **Статус форка относительно апстрима:**  
> Репозиторий `gosha20777/try-nix-os` находится на ветке `main` (ровно на 4 коммита впереди `omacom/try-omarchy`, 0 позади). Эти коммиты адаптируют только сценарий загрузки гостевой NixOS (файлы `run-qemu-gpu.sh`, `build-app.sh`, `open-qemu-gpu.sh`, `Makefile`, `scripts/build-cache.py` и Swift-хелпер для загрузки внешнего ISO с разреженным диском 64 GiB) и совершенно **не затрагивают** графический стек virgl/QEMU и его патчи. Поэтому добавление двух патчей OmacVM ложится на абсолютно чистое дерево virglrenderer, а `make runtime FORCE=1` пересобирает стек без побочных эффектов.

### 3.1. Как устроен virglrenderer в проекте (исходные данные)

- **Источник и сборка**:
  Файл `macos/build-qemu-gpu-runtime.sh` скачивает зафиксированный архив исходников `virglrenderer`:
  - Коммит: `ca50e008863837e094747a69974dde3ae148aeaa` (1.3.0).
  - URL: `https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/ca50e008863837e094747a69974dde3ae148aeaa/virglrenderer-ca50e008863837e094747a69974dde3ae148aeaa.tar.gz`
  - Контрольная сумма архива: `e7c512469a207444103ead88a8992a7077173e21771623845d4567f8128b5dc1`
  - Также скачивается tap `startergo/homebrew-virglrenderer` (коммит `e7daef144d249a38d6206153e6146539f893eae2`), откуда берутся 21 платформенный патч.
- **Механизм применения существующих патчей**:
  Собственные патчи репозитория хранятся в `macos/patches/`.
  Существующий пример:
  - Файлы: `macos/patches/virgl-native-opengl.patch` и `macos/patches/virgl-ctx0-upload-flush.patch`.
  - В `macos/build-qemu-gpu-runtime.sh`:
    1. Задаётся путь к патчу:
       ```bash
       virgl_native_patch="$native_dir/patches/virgl-native-opengl.patch"
       ```
    2. Задаётся контрольная сумма SHA256:
       ```bash
       virgl_native_patch_sha256=692ed73cf88780b4c0e04c56e3cfb21cec761768dea909d755624e07d82fc60c
       ```
    3. Выполняется валидация и наложение через `patch -p1`:
       ```bash
       verify_file_sha "Native OpenGL browser compatibility patch" "$virgl_native_patch" "$virgl_native_patch_sha256"
       patch -d "$virgl_source" -p1 -f -i "$virgl_native_patch"
       ```
- **Кэш сборки**:
  Скрипт `scripts/build-cache.py` (строка 150) отслеживает все файлы в каталоге `macos/patches/`. Добавление новых файлов патчей автоматически инвалидирует кэш сборки `runtime`.

### 3.2. Проверка наложения патчей (`patch --dry-run`) и критичность порядка

Была проведена полная верификация применения патчей на реальном дереве исходников virglrenderer `ca50e008863837e094747a69974dde3ae148aeaa`.

> **Порядок наложения патчей критически важен:**
> - Патч `virgl-shader-failure-skip-draws.patch` успешно накладывается (все 18/18 хунков со 100% совпадением контекста без сдвигов) **только после** применения 21 патча из tap (`$virgl_tap/patches/*`) + двух существующих патчей репозитория `virgl-native-opengl.patch` и `virgl-ctx0-upload-flush.patch`. Если попытаться применить его на чистые немодифицированные исходники virglrenderer 1.3.0, хунк #5 завершается ошибкой (`FAILED at 1458`).
> - Патч `virgl-core-instance-id.patch` накладывается на строку 6361 со смещением +7 строк без конфликтов (0 rejects).
> - Поэтому регистрировать оба патча в `macos/build-qemu-gpu-runtime.sh` необходимо строго **в конце цепочки** (после `virgl_upload_flush_patch`). При таком порядке оба патча применяются чисто с нулевым количеством ошибок и не требуют адаптации контекста (rebase).

---

### 3.3. Добавление файлов патчей в `macos/patches/`

> **ВНИМАНИЕ: обязательно скачивайте файлы патчей через `curl`!**  
> Не копируйте текст патчей из Markdown через буфер обмена: текстовые редакторы и рендереры Markdown часто отсекают концевые пробелы (trailing spaces) в строках контекста diff (в частности, в `virgl-shader-failure-skip-draws.patch` теряются 2 байта trailing space в строке `    }`), из-за чего хэш SHA256 изменится (`49aac0d0...` вместо `7611495f...`), и встроенная проверка `verify_file_sha` в скрипте сборки прервёт процесс.  
> Тексты diff приведены ниже исключительно для ознакомления и аудита.

Выполните на Mac в корне репозитория `try-nix-os`:

```bash
# 1. Скачивание патча для gl_InstanceID
curl -fL https://raw.githubusercontent.com/gillesgoetsch/OmacVM/main/app/runtime/patches/virgl-core-instance-id.patch \
  -o macos/patches/virgl-core-instance-id.patch

# Проверка контрольной суммы (должна совпасть с 67de90ba...):
shasum -a 256 macos/patches/virgl-core-instance-id.patch
# Вывод: 67de90babfec3f4abf2b1747f6637bd74e4cd5a2c2cdf0b44eaaeb0e33a6f0d6  macos/patches/virgl-core-instance-id.patch

# 2. Скачивание патча изоляции сбоев шейдеров
curl -fL https://raw.githubusercontent.com/gillesgoetsch/OmacVM/main/app/runtime/patches/virgl-shader-failure-skip-draws.patch \
  -o macos/patches/virgl-shader-failure-skip-draws.patch

# Проверка контрольной суммы (должна совпасть с 7611495f...):
shasum -a 256 macos/patches/virgl-shader-failure-skip-draws.patch
# Вывод: 7611495f5afd94b016c9cd7126a457bfdcb13f60df46b5a754cb3d584a4002f1  macos/patches/virgl-shader-failure-skip-draws.patch
```

<details>
<summary>Справочный листинг: macos/patches/virgl-core-instance-id.patch</summary>

```diff
virglrenderer: no "#extension GL_ARB_draw_instanced" in core GLSL

What: a shader that reads gl_InstanceID got "#extension GL_ARB_draw_instanced :
require". gl_InstanceID is core since GLSL 1.40 and Apple's core profile refuses
the extension, so every such shader failed to compile on the Mac. The requirement
is now dropped for GLSL >= 140, like ARB_texture_rectangle already was.
Why: found in a Chrome WebGL soak (tests/graphics/soak.sh): "extension
'GL_ARB_draw_instanced' is not supported". Instanced WebGL drawing (ANGLE emits
gl_InstanceID) stopped Chrome's whole GL context before; with
virgl-shader-failure-skip-draws.patch it skipped those draws; now it draws.
Upstream: upstreamable; not sent.
Tests: Tests/virgl/test-integer-sampler-shader.c "vertex shader reading
gl_InstanceID" (compiled by the Mac's OpenGL; fails without this patch).
--- a/src/vrend/vrend_shader.c
+++ b/src/vrend/vrend_shader.c
@@ -6354,6 +6354,9 @@
       for (uint32_t i = 0; i < ARRAY_SIZE(shader_req_table); i++) {
          if (shader_req_table[i].key == SHADER_REQ_SAMPLER_RECT && ctx->glsl_ver_required >= 140)
             continue;
+         /* gl_InstanceID is core in GLSL 1.40; Apple's core profile refuses the extension. */
+         if (shader_req_table[i].key == SHADER_REQ_INSTANCE_ID && ctx->glsl_ver_required >= 140)
+            continue;
 
          if (ctx->shader_req_bits & shader_req_table[i].key) {
             emit_ext(glsl_strbufs, shader_req_table[i].string, "require");
```
</details>

<details>
<summary>Справочный листинг: macos/patches/virgl-shader-failure-skip-draws.patch</summary>

```diff
virglrenderer: skip the draws of a shader the host GL refuses, keep the context

What: when vrend cannot translate a shader the guest's Mesa already accepted
(TGSI->GLSL), or the Mac's OpenGL refuses to compile or link it (a GLSL gap or a
host limit, e.g. Apple's 4096 uniform components), the shader is marked failed
and the draws and compute dispatches that need it are skipped, like a native
driver does. The context keeps running. Failures are logged three times per context at most (the first with the
GLSL and the GL info log), one line about skipped draws or dispatches once per
context (compute too, though Apple's GL 4.1 has no compute shaders). A
failed compile is never retried; failed links are remembered per fragment shader
(by a serial that is never reused, unlike GL names) so a page that keeps drawing
does not relink every draw.
Why: upstream reports VIRGL_ERROR_CTX_ILLEGAL_SHADER, which stops the whole guest
context for good; the guest is never told (stock Mesa has no reset query on
virgl), so Chrome's GPU process keeps drawing into a dead context and the tab
hangs (Basemark Web 3.0, finding 23). OMACVM_VIRGL_SHADER_FAILURES=lose restores
the upstream behaviour (then virgl-context-loss-report.patch tells the guest).
Upstream: upstreamable in spirit (behaviour change, would need a flag or a
discussion on the virglrenderer list); not sent.
Tests: Tests/virgl/test-context-loss.c (build time: a program over Apple's uniform
limit and a shader with a property the translator lacks are skipped, the context
stays alive, 20 draws link once and log one dropped line);
tests/graphics/context-loss.sh --expect contain (Chrome WebGL page keeps drawing correct frames after a refused
shader, with virgl-test-shader-fault.patch).
--- a/src/vrend/vrend_renderer.c
+++ b/src/vrend/vrend_renderer.c
@@ -357,6 +357,9 @@
    struct list_head fence_wait_list;
    struct vrend_fence *fence_waiting;
 
+   /* Never reused, unlike GL names: keys the failed-link memo of each shader. */
+   uint32_t shader_serial;
+
    int gl_major_ver;
    int gl_minor_ver;
 
@@ -513,6 +516,16 @@
    GLuint last_pipeline_id;
    bool is_compiled;
    bool is_linked; /* only used for separable shaders */
+   /* The host GL refused it; never retried, draws that need it are skipped. */
+   bool compile_failed;
+   bool link_failed; /* separable or compute program */
+   uint32_t serial;
+   /* Last programs with this fragment shader that failed to link (by serial). */
+   struct {
+      uint32_t vs, gs, tcs, tes;
+      bool dual_src;
+   } failed_links[4];
+   unsigned next_failed_link;
    struct vrend_shader_key key;
    struct list_head programs;
 };
@@ -879,6 +892,9 @@
    vrend_context_fence_retire fence_retire;
    void *fence_retire_data;
 
+   unsigned shader_failures;
+   bool dropped_draws_logged;
+
 #ifdef ENABLE_TRACING
    struct hash_table *active_markers;
 #endif
@@ -1143,8 +1159,47 @@
    virgl_error("%s: context error reported %d \"%s\" %s %d\n", fname,
                ctx->ctx_id, ctx->debug_name, vrend_ctx_error_strings[error],
                value);
+}
+
+/* The guest compiled the shader; only the host GL refused it (a translation gap or a
+ * host limit). A native driver skips the draws that need such a shader, so do the
+ * same instead of stopping the whole context, which leaves the guest app drawing into
+ * a dead context. OMACVM_VIRGL_SHADER_FAILURES=lose keeps the upstream behaviour.
+ * Returns true when the caller should log the details. */
+static bool vrend_shader_failures_lose(void)
+{
+   static int lose = -1;
+
+   if (lose < 0) {
+      const char *policy = getenv("OMACVM_VIRGL_SHADER_FAILURES");
+      lose = policy && !strcmp(policy, "lose");
+   }
+   return lose;
+}
+
+static bool vrend_report_shader_failure(struct vrend_context *ctx, const char *what)
+{
+   if (vrend_shader_failures_lose()) {
+      vrend_report_context_error(ctx, VIRGL_ERROR_CTX_ILLEGAL_SHADER, 0);
+      return true;
+   }
+
+   ctx->shader_failures++;
+   if (ctx->shader_failures <= 3)
+      virgl_error("context %d (%s): the host refused a shader (%s), draws that need it "
+                  "are skipped%s\n", ctx->ctx_id, ctx->debug_name, what,
+                  ctx->shader_failures == 3 ? "; further failures are not logged" : "");
+   return ctx->shader_failures == 1;
 }
 
+static void vrend_report_dropped_draws(struct vrend_context *ctx, const char *what)
+{
+   if (ctx->dropped_draws_logged)
+      return;
+   ctx->dropped_draws_logged = true;
+   virgl_error("%s: %s (logged once per context)\n", what, ctx->debug_name);
+}
+
 #define CORE_PROFILE_WARN_NONE 0
 #define CORE_PROFILE_WARN_STIPPLE 1
 #define CORE_PROFILE_WARN_POLYGON_MODE 2
@@ -1403,6 +1458,9 @@
    GLint param;
    const char *shader_parts[SHADER_MAX_STRINGS];
    char *modified_shaders[SHADER_MAX_STRINGS] = {NULL};
+
+   if (shader->compile_failed)
+      return false;
 
    /* Firefox uses GL_EXT_shader_texture_lod (GLES extension), but on OpenGL 4.1 Core Profile
     * textureLod is built into the core spec - no extension directive needed.
@@ -1452,9 +1510,13 @@
       char infolog[65536];
       int len;
       glGetShaderInfoLog(shader->id, 65536, &len, infolog);
-      vrend_report_context_error(sub_ctx->parent, VIRGL_ERROR_CTX_ILLEGAL_SHADER, 0);
-      virgl_error("Shader failed to compile\n%s\n", infolog);
-      vrend_shader_dump(shader);
+      shader->compile_failed = true;
+      if (vrend_report_shader_failure(sub_ctx->parent, "compile")) {
+         virgl_error("Shader failed to compile\n%s\n", infolog);
+         vrend_shader_dump(shader);
+      }
+      glDeleteShader(shader->id);
+      shader->id = 0;
       return false;
    }
 
@@ -1946,6 +2008,9 @@
    int i;
    char name[64];
 
+   if (shader->compile_failed || shader->link_failed)
+      return false;
+
    if (type == PIPE_SHADER_VERTEX || type == PIPE_SHADER_GEOMETRY ||
        type == PIPE_SHADER_TESS_EVAL)
        set_stream_out_varyings(sub_ctx, shader->program_id, &shader->sel->sinfo);
@@ -1992,9 +2057,9 @@
    shader->is_linked = vrend_link(shader->program_id);
 
    if (!shader->is_linked) {
-      /* dump shaders */
-      vrend_report_context_error(sub_ctx->parent, VIRGL_ERROR_CTX_ILLEGAL_SHADER, 0);
-      vrend_shader_dump(shader);
+      shader->link_failed = true;
+      if (vrend_report_shader_failure(sub_ctx->parent, "separable link"))
+         vrend_shader_dump(shader);
    }
 
    return shader->is_linked;
@@ -2003,15 +2068,20 @@
 static struct vrend_linked_shader_program *add_cs_shader_program(struct vrend_context *ctx,
                                                                  struct vrend_shader *cs)
 {
-   struct vrend_linked_shader_program *sprog = CALLOC_STRUCT(vrend_linked_shader_program);
+   struct vrend_linked_shader_program *sprog;
    GLuint prog_id;
+
+   if (cs->link_failed)
+      return NULL;
+
+   sprog = CALLOC_STRUCT(vrend_linked_shader_program);
    prog_id = glCreateProgram();
    glAttachShader(prog_id, cs->id);
 
    if (!vrend_link(prog_id)) {
-      /* dump shaders */
-      vrend_report_context_error(ctx, VIRGL_ERROR_CTX_ILLEGAL_SHADER, 0);
-      vrend_shader_dump(cs);
+      cs->link_failed = true;
+      if (vrend_report_shader_failure(ctx, "compute link"))
+         vrend_shader_dump(cs);
       glDeleteProgram(prog_id);
       free(sprog);
       return NULL;
@@ -2034,11 +2104,52 @@
 
 static inline bool
 vrend_link_stage(struct vrend_shader *stage) {
-   if (!stage->is_linked)
+   if (!stage->is_linked && !stage->link_failed) {
       stage->is_linked = vrend_link(stage->program_id);
+      stage->link_failed = !stage->is_linked;
+   }
    return stage->is_linked;
 }
 
+static uint32_t vrend_shader_serial(const struct vrend_shader *shader)
+{
+   return shader ? shader->serial : 0;
+}
+
+static bool vrend_program_failed_before(const struct vrend_shader *vs,
+                                        const struct vrend_shader *fs,
+                                        const struct vrend_shader *gs,
+                                        const struct vrend_shader *tcs,
+                                        const struct vrend_shader *tes,
+                                        bool dual_src)
+{
+   for (unsigned i = 0; i < ARRAY_SIZE(fs->failed_links); i++) {
+      if (fs->failed_links[i].vs == vrend_shader_serial(vs) &&
+          fs->failed_links[i].gs == vrend_shader_serial(gs) &&
+          fs->failed_links[i].tcs == vrend_shader_serial(tcs) &&
+          fs->failed_links[i].tes == vrend_shader_serial(tes) &&
+          fs->failed_links[i].dual_src == dual_src)
+         return true;
+   }
+   return false;
+}
+
+static void vrend_remember_failed_program(const struct vrend_shader *vs,
+                                          struct vrend_shader *fs,
+                                          const struct vrend_shader *gs,
+                                          const struct vrend_shader *tcs,
+                                          const struct vrend_shader *tes,
+                                          bool dual_src)
+{
+   unsigned i = fs->next_failed_link++ % ARRAY_SIZE(fs->failed_links);
+
+   fs->failed_links[i].vs = vrend_shader_serial(vs);
+   fs->failed_links[i].gs = vrend_shader_serial(gs);
+   fs->failed_links[i].tcs = vrend_shader_serial(tcs);
+   fs->failed_links[i].tes = vrend_shader_serial(tes);
+   fs->failed_links[i].dual_src = dual_src;
+}
+
 static struct vrend_linked_shader_program *add_shader_program(struct vrend_sub_context *sub_ctx,
                                                               struct vrend_shader *vs,
                                                               struct vrend_shader *fs,
@@ -2148,18 +2259,19 @@
          glDeleteProgram(prog_id);
       }
 
+      vrend_remember_failed_program(vs, fs, gs, tcs, tes, sprog->dual_src_linked);
       free(sprog);
 
-      /* dump shaders */
-      vrend_report_context_error(sub_ctx->parent, VIRGL_ERROR_CTX_ILLEGAL_SHADER, 0);
-      vrend_shader_dump(vs);
-      if (tcs)
-         vrend_shader_dump(tcs);
-      if (tes)
-         vrend_shader_dump(tes);
-      if (gs)
-         vrend_shader_dump(gs);
-      vrend_shader_dump(fs);
+      if (vrend_report_shader_failure(sub_ctx->parent, "link")) {
+         vrend_shader_dump(vs);
+         if (tcs)
+            vrend_shader_dump(tcs);
+         if (tes)
+            vrend_shader_dump(tes);
+         if (gs)
+            vrend_shader_dump(gs);
+         vrend_shader_dump(fs);
+      }
       return NULL;
    }
 
@@ -4439,8 +4551,15 @@
                                       shader->sel->req_local_mem, key, &shader->sel->sinfo,
                                       &shader->var_sinfo, &shader->glsl_strings);
       if (!ret) {
-         vrend_report_context_error(ctx, VIRGL_ERROR_CTX_ILLEGAL_SHADER, shader->sel->type);
-         return -1;
+         if (vrend_shader_failures_lose()) {
+            vrend_report_context_error(ctx, VIRGL_ERROR_CTX_ILLEGAL_SHADER, shader->sel->type);
+            return -1;
+         }
+         /* A gap in the TGSI -> GLSL translation: the guest accepted the shader, so
+          * treat it like one the host GL refuses. It has no GLSL and is never compiled. */
+         shader->compile_failed = true;
+         if (vrend_report_shader_failure(ctx, "translation"))
+            vrend_shader_dump(shader);
       }
    } else if (!ctx->shader_cfg.use_gles && shader->sel->type != PIPE_SHADER_TESS_CTRL) {
       vrend_report_context_error(ctx, VIRGL_ERROR_CTX_ILLEGAL_SHADER, shader->sel->type);
@@ -4481,6 +4600,7 @@
 
    if (!shader) {
       shader = CALLOC_STRUCT(vrend_shader);
+      shader->serial = ++vrend_state.shader_serial;
       shader->sel = sel;
       list_inithead(&shader->programs);
       strarray_alloc(&shader->glsl_strings, SHADER_MAX_STRINGS);
@@ -5718,6 +5838,7 @@
 
    vrend_fill_shader_key(sub_ctx, sel, &shader->key);
 
+   shader->serial = ++vrend_state.shader_serial;
    shader->sel = sel;
    list_inithead(&shader->programs);
    strarray_alloc(&shader->glsl_strings, SHADER_MAX_STRINGS);
@@ -5861,6 +5982,8 @@
    if (!same_prog) {
       prog = lookup_shader_program(sub_ctx, vs_id, fs_id, gs_id, tcs_id, tes_id, dual_src);
       if (!prog) {
+         if (vrend_program_failed_before(vs, fs, gs, tcs, tes, dual_src))
+            return PROGRAMM_ERROR;
          prog = add_shader_program(sub_ctx,
                                    sub_ctx->shaders[PIPE_SHADER_VERTEX]->current,
                                    sub_ctx->shaders[PIPE_SHADER_FRAGMENT]->current,
@@ -6061,7 +6184,7 @@
       program_select_result = vrend_select_program(sub_ctx, info->vertices_per_patch);
 
    if (!sub_ctx->prog || program_select_result == PROGRAMM_ERROR) {
-      virgl_error("Dropping rendering due to missing shaders: %s\n", ctx->debug_name);
+      vrend_report_dropped_draws(ctx, "Dropping rendering due to missing shaders");
       return 0;
    }
 
@@ -6314,7 +6437,7 @@
       }
       if (!sub_ctx->shaders[PIPE_SHADER_COMPUTE]->current->is_compiled) {
          if (!vrend_compile_shader(sub_ctx, sub_ctx->shaders[PIPE_SHADER_COMPUTE]->current)) {
-            virgl_error("Failure to compile compute shader variant: %s\n", ctx->debug_name);
+            vrend_report_dropped_draws(ctx, "Skipping compute shader execution, its shader failed to compile");
             return;
          }
       }
@@ -6340,8 +6463,7 @@
    }
 
    if (!sub_ctx->prog) {
-      virgl_error("%s: Skipping compute shader execution due to missing shaders: %s\n",
-                   __func__, ctx->debug_name);
+      vrend_report_dropped_draws(ctx, "Skipping compute shader execution due to missing shaders");
       return;
    }
```
</details>

---

### 3.4. Регистрация патчей в `macos/build-qemu-gpu-runtime.sh`

В файле `macos/build-qemu-gpu-runtime.sh` требуется внести три фрагмента правок (строго после существующих патчей):

```diff
--- a/macos/build-qemu-gpu-runtime.sh
+++ b/macos/build-qemu-gpu-runtime.sh
@@ -91,6 +91,8 @@ fence_poll_patch="$native_dir/patches/qemu-darwin-gpu-fence-poll.patch"
 virgl_native_patch="$native_dir/patches/virgl-native-opengl.patch"
 virgl_upload_flush_patch="$native_dir/patches/virgl-ctx0-upload-flush.patch"
+virgl_instance_id_patch="$native_dir/patches/virgl-core-instance-id.patch"
+virgl_skip_draws_patch="$native_dir/patches/virgl-shader-failure-skip-draws.patch"
 prepare_runtime="$native_dir/prepare-qemu-gpu-runtime.sh"
 pinned_bottles="$native_dir/pinned-runtime-bottles.sh"
 
@@ -124,6 +126,8 @@ fence_poll_patch_sha256=1ac407bdb617dfc52d004d0ebd0d07641d920f7d3a9756223c6426
 virgl_native_patch_sha256=692ed73cf88780b4c0e04c56e3cfb21cec761768dea909d755624e07d82fc60c
 virgl_upload_flush_patch_sha256=e5de1617bfeeb2e0ea0fa5cc5c4192f34c896c86efc51e0f68cfa14057afcac0
+virgl_instance_id_patch_sha256=67de90babfec3f4abf2b1747f6637bd74e4cd5a2c2cdf0b44eaaeb0e33a6f0d6
+virgl_skip_draws_patch_sha256=7611495f5afd94b016c9cd7126a457bfdcb13f60df46b5a754cb3d584a4002f1
 strchrnul_patch_sha256=ec1048dd0e8ebe53bf7e8a3bca9bf2f5f4336cd607d4cd077437470e9a32094a
 usb_exact_bus_patch_sha256=5e39159171295c566d014a1ef2744130f80fa02b742c349fa47373b00ae697ec
 minimum_guest_size_patch_sha256=f01e20999bf87821639c93f3489eb093b292c48b107a14ba4fbdad5cbf5840a5
@@ -696,6 +700,10 @@ verify_file_sha "Native OpenGL browser compatibility patch" "$virgl_native_patc
 patch -d "$virgl_source" -p1 -f -i "$virgl_native_patch"
 verify_file_sha "Context 0 upload flush patch" "$virgl_upload_flush_patch" "$virgl_upload_flush_patch_sha256"
 patch -d "$virgl_source" -p1 -f -i "$virgl_upload_flush_patch"
+verify_file_sha "Core GLSL gl_InstanceID patch" "$virgl_instance_id_patch" "$virgl_instance_id_patch_sha256"
+patch -d "$virgl_source" -p1 -f -i "$virgl_instance_id_patch"
+verify_file_sha "Shader failure containment patch" "$virgl_skip_draws_patch" "$virgl_skip_draws_patch_sha256"
+patch -d "$virgl_source" -p1 -f -i "$virgl_skip_draws_patch"
 virgl_build="$virgl_source/build"
 meson="$tool_root/$meson_root/meson.py"
 # Optimize the graphics command path while retaining assertions and diagnostics.
```

---

## 4. Сборка и запуск на Mac

### 4.1. Требования к окружению хоста
- Компьютер: Apple Silicon Mac (M1/M2/M3/M4, `arm64`).
- ОС: macOS 15.0 Sequoia или новее.
- Инструменты (проверяются командой `make doctor`):
  `curl`, `pkg-config`, `python3`, `swift`, `xcrun` (Xcode Command Line Tools).

### 4.2. Сборка приложения
Перейдите в корень репозитория `try-nix-os` на хосте macOS:

```bash
# 1. Проверка готовности тулчейна
make doctor

# 2. Пересборка нативного runtime с новыми патчами
# Флаг FORCE=1 обязателен, чтобы сбросить кэш предыдущей сборки virglrenderer
make runtime FORCE=1

# 3. Сборка приложения
# Для локальной разработки нотаризация НЕ ТРЕБУЕТСЯ.
# Параметр DEVELOPMENT_SIGN_IDENTITY=- включает ad-hoc подпись,
# избавляя от необходимости создавать платный сертификат Apple Developer.
make app DEVELOPMENT_SIGN_IDENTITY=-
```

### 4.3. Размещение бинарных файлов внутри бандла
В соответствии с `Makefile:6` (`override APP := $(DIST)/app.noindex/Try Omarchy.app`) и `macos/build-app.sh:111` каталог собранного бандла на диске всегда имеет путь:
`dist/app.noindex/Try Omarchy.app`

> **Важная деталь отображения в macOS Finder:**  
> Хотя на диске каталог всегда называется `Try Omarchy.app`, скрипт сборки форка (`macos/build-app.sh:83-93, 262-263`) устанавливает в `Contents/Info.plist` поля `CFBundleName` и `CFBundleDisplayName` равными `Try NixOS` (или `Try NixOS Dev`), а bundle ID — `dev.trynixos.native[.development]`. Поэтому в Finder, Dock и строке меню macOS приложение отображается как **«Try NixOS»**, тогда как физическая папка на диске остаётся **`Try Omarchy.app`**. Не ищите на диске каталог `Try NixOS.app`.  
> Валидатор путей в лаунчере (`macos/Sources/OmarchyVMHelper/QEMUGPULauncher.swift:313-321`) явно принимает оба имени бандла (`Try Omarchy.app` и `Try NixOS.app`).

Бинарники располагаются по следующим путям:
- Библиотека virglrenderer:
  `Contents/Resources/runtime/lib/libvirglrenderer.1.dylib`
- Исполняемый файл QEMU (переименованный из `qemu-system-aarch64` по отображаемому имени приложения согласно `macos/build-app.sh:313`):
  `Contents/Resources/runtime/bin/Try Omarchy`
- Зависимости (libepoxy, ANGLE EGL/GLESv2, libslirp):
  `Contents/Resources/runtime/lib/`

При сборке исполняемый файл `Try Omarchy` автоматически подписывается с необходимыми entitlements для гипервизора macOS:
`macos/qemu-hvf.entitlements` (`com.apple.security.hypervisor`).
### 4.4. Запуск виртуальной машины
```bash
# Запуск собранного приложения
make run DEVELOPMENT_SIGN_IDENTITY=-

# Или запуск без сохранения состояния (одноразовая сессия):
make run-ephemeral DEVELOPMENT_SIGN_IDENTITY=-
```

### 4.5. Управление диском виртуальной машины
- **Нужно ли пересоздавать диск ВМ?**
  **НЕТ!** Обновление затрагивает только хостовую библиотеку `virglrenderer`. Существующий диск виртуальной машины сохраняет все установленные пакеты, конфигурации и пользовательские данные.
- **Если диск всё же потребуется сбросить:**
  - Штатный сброс через приложение:
    ```bash
    make reset DEVELOPMENT_SIGN_IDENTITY=-
    ```
  - Полное удаление диска и состояния ВМ:
    Диск расположен по пути `~/Library/Application Support/Try Omarchy/shell/disk.img` (либо `Try NixOS`). Для полного сброса достаточно удалить этот каталог:
    ```bash
    rm -rf "$HOME/Library/Application Support/Try Omarchy/shell"
    ```
    Либо выполнить глубокую очистку:
    ```bash
    make clean-all
    ```

---

## 5. Тестирование на Mac (host-side)

### Шаг 5.1. Автоматические тесты регрессий virglrenderer
При выполнении `make runtime FORCE=1` скрипт автоматически запускает хостовые тесты драйвера:
```bash
python3 "$virgl_tap/tests/run-driver-regressions.py" ...
python3 "$native_dir/Tests/virgl/run-regressions.py" ...
```
Они компилируют шейдеры и проверяют переходы состояний блендинга и выбор форматов без запуска виртуальной машины.

### Шаг 5.2. Подключение готового хостового теста для `gl_InstanceID` (из OmacVM)
В репозитории try-omarchy / try-nix-os ни один существующий тест (`guest/package/tests/virgl-smoke.c`, `macos/Tests/virgl/*`, `.github/workflows/guest-desktop.yml`) не проверял использование `gl_InstanceID`.

Для хостовой проверки на Mac используйте проверенный готовый тест `test-integer-sampler-shader.c` из репозитория OmacVM:
- Файл: `app/runtime/Tests/virgl/test-integer-sampler-shader.c` в репозитории [OmacVM](https://github.com/gillesgoetsch/OmacVM/blob/main/app/runtime/Tests/virgl/test-integer-sampler-shader.c).
- Этот тест содержит отдельный законченный кейс:
  ```c
  /* Instanced drawing (WebGL through ANGLE): gl_InstanceID is core GLSL; Apple's
   * core profile refuses "#extension GL_ARB_draw_instanced : require". */
  failed |= convert("vertex shader reading gl_InstanceID",
                    "VERT\nDCL IN[0]\nDCL SV[0], INSTANCEID\nDCL OUT[0], POSITION\n"
                    "DCL TEMP[0]\nI2F TEMP[0].x, SV[0].xxxx\nADD OUT[0], IN[0], TEMP[0].xxxx\nEND\n",
                    "gl_InstanceID", "GL_ARB_draw_instanced", false, have_gl);
  ```
- Тест транслирует TGSI, проверяет, что в результирующем GLSL присутствует `gl_InstanceID` и **отсутствует** `#extension GL_ARB_draw_instanced`, а затем компилирует полученный шейдер напрямую через нативный Apple CGL Core Profile контекст macOS.
- Для подключения скопируйте `test-integer-sampler-shader.c` в `macos/Tests/virgl/` и зарегистрируйте запуск в `macos/Tests/virgl/run-regressions.py` по существующему образцу (`run_test(...)`).

---

## 6. Проверка из гостевой VM после перезагрузки

После запуска ВМ с пропатченным приложением выполните следующие проверки в гостевой системе:

### Проверка 6.1. Автономный C-пробник `gl_InstanceID`

Автономный тестовый стенд на EGL + GLES 3.0, воспроизводящий логику Kitty.

Создайте файл `/tmp/test-probe.c`:

```c
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (EGL %x GL %x)\n", __LINE__, #x, eglGetError(), glGetError()); exit(1); } } while (0)

static const char *vs_src =
    "#version 300 es\n"
    "in vec2 position;\n"
    "flat out int v_instance;\n"
    "void main() {\n"
    "    v_instance = gl_InstanceID;\n"
    "    gl_Position = vec4(position, 0.0, 1.0);\n"
    "}\n";

static const char *fs_src =
    "#version 300 es\n"
    "precision mediump float;\n"
    "flat in int v_instance;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    if (v_instance == 0) {\n"
    "        fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
    "    } else {\n"
    "        fragColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "    }\n"
    "}\n";

int main(void) {
    EGLDisplay display = eglGetPlatformDisplay(0x31DD, EGL_DEFAULT_DISPLAY, NULL);
    CHECK(display != EGL_NO_DISPLAY);
    CHECK(eglInitialize(display, NULL, NULL));
    CHECK(eglBindAPI(EGL_OPENGL_ES_API));

    EGLint attrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, 0x40,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config; EGLint count;
    CHECK(eglChooseConfig(display, attrs, &config, 1, &count) && count == 1);

    EGLint surface_attrs[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attrs);
    EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
    CHECK(context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE);
    CHECK(eglMakeCurrent(display, surface, surface, context));

    printf("Renderer: %s\n", glGetString(GL_RENDERER));
    printf("Version:  %s\n", glGetString(GL_VERSION));

    GLuint vs = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(vs, 1, &vs_src, NULL);
    glCompileShader(vs);
    GLint ok = 0;
    glGetShaderiv(vs, GL_COMPILE_STATUS, &ok);
    CHECK(ok == GL_TRUE);

    GLuint fs = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(fs, 1, &fs_src, NULL);
    glCompileShader(fs);
    glGetShaderiv(fs, GL_COMPILE_STATUS, &ok);
    CHECK(ok == GL_TRUE);

    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    CHECK(ok == GL_TRUE);
    glUseProgram(prog);

    float verts[] = {
        -1.0f, -1.0f,
         3.0f, -1.0f,
        -1.0f,  3.0f,
    };
    GLuint vbo;
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);

    GLint loc = glGetAttribLocation(prog, "position");
    CHECK(loc >= 0);
    glEnableVertexAttribArray(loc);
    glVertexAttribPointer(loc, 2, GL_FLOAT, GL_FALSE, 0, NULL);

    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glDrawArraysInstanced(GL_TRIANGLES, 0, 3, 1);
    glFinish();

    unsigned char pixel[4] = {0};
    glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    printf("Read pixel at (8,8): RGBA = (%d, %d, %d, %d)\n", pixel[0], pixel[1], pixel[2], pixel[3]);

    if (pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255) {
        printf("PASS: Shader with active gl_InstanceID rendered red pixel successfully!\n");
    } else {
        printf("FAIL: Shader with active gl_InstanceID dropped by host virglrenderer (expected (255,0,0,255), got (%d,%d,%d,%d))\n",
               pixel[0], pixel[1], pixel[2], pixel[3]);
    }

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);
    return 0;
}
```

Скомпилируйте и запустите в гостевой системе:
```bash
nix-shell -p libglvnd.dev --run "gcc -O2 /tmp/test-probe.c -o /tmp/test-probe -lEGL -lGLESv2 && /tmp/test-probe"
```

**Ожидаемые результаты:**
- **До применения патча на Mac (подтверждено экспериментом):**
  ```text
  Renderer: virgl (Apple M3)
  Version:  OpenGL ES 3.0 Mesa 26.2.3
  Read pixel at (8,8): RGBA = (0, 0, 0, 0)
  FAIL: Shader with active gl_InstanceID dropped by host virglrenderer (expected (255,0,0,255), got (0,0,0,0))
  ```
- **После применения патча на Mac:**
  ```text
  Renderer: virgl (Apple M3)
  Version:  OpenGL ES 3.0 Mesa 26.2.3
  Read pixel at (8,8): RGBA = (255, 0, 0, 255)
  PASS: Shader with active gl_InstanceID rendered red pixel successfully!
  ```

---

### Проверка 6.2. Запуск необёрнутого Kitty без `LIBGL_ALWAYS_SOFTWARE`

Запустите бинарник Kitty напрямую (без софтверной обёртки):

```bash
# Прямой запуск kitty 0.49.0 / 0.50.0:
/nix/store/jaisq8ij47ns8vpic4pllc7md4xyn0vf-kitty-0.49.0/bin/kitty
```

**Ожидаемый результат:**
- Окно Kitty отображается мгновенно, фон окна непрозрачный, шрифт четко отрисован через аппаратный `virgl`.
- В логах niri и dmesg нет ошибок DRM/virgl.

### Проверка 6.3. Скриншот и проверка пикселей окна Kitty через niri

В гостевой системе захват окон выполняется штатными средствами niri без сторонних утилит вроде `grim`:

```bash
# 1. Запуск необёрнутого kitty в фоновом режиме
/nix/store/jaisq8ij47ns8vpic4pllc7md4xyn0vf-kitty-0.49.0/bin/kitty &
KITTY_PID=$!
sleep 2

# 2. Снятие скриншота активного окна через niri IPC
# Снимок автоматически сохраняется в каталог ~/Pictures/Screenshots/
niri msg action screenshot-window
sleep 1

# 3. Инспекция пикселей последнего скриншота через ImageMagick
LATEST_SCREENSHOT=$(ls -t ~/Pictures/Screenshots/Screenshot*.png 2>/dev/null | head -n1)
nix-shell -p imagemagick --run "
  magick \"$LATEST_SCREENSHOT\" -format 'mean=%[fx:mean] max=%[fx:maxima]\n' info:
"

kill $KITTY_PID
```

**Интерпретация результатов:**
- **До фикса (сломано):** `mean=0 max=0` — буфер окна полностью пустой/прозрачно-чёрный `(0, 0, 0, 0)`.
- **После фикса (исправлено):** `max > 0` (например, `max=1`), `mean > 0` — в буфере присутствуют реальные непрозрачные пиксели фона терминала и символов текста.

---

## 7. Риски, откат и решение проблем

### 7.1. Риски
- Риск минимален: патчи затрагивают только поведение хостовой библиотеки `virglrenderer` при трансляции GLSL на macOS и не меняют ни QEMU, ни структуру гостевых дисков.
- Патч `virgl-core-instance-id.patch` лишь приводит генерацию GLSL в соответствие со спецификацией OpenGL Core Profile (отключая избыточное и невалидное расширение).
- Патч `virgl-shader-failure-skip-draws.patch` повышает отказоустойчивость: при отказе хостового GL контекст не погибает.

### 7.2. Откат изменений
1. **В git репозитории на Mac:**
   Перед началом работы создайте отдельную ветку:
   ```bash
   git checkout -b fix/virgl-instance-id
   ```
   В случае необходимости отката:
   ```bash
   git checkout main
   make runtime FORCE=1
   make app DEVELOPMENT_SIGN_IDENTITY=-
   ```
2. **Возврат на официальный релиз:**
   Если сборка из исходников вызвала затруднения, можно скачать готовый `.dmg` из релизов:
   - Форка: `https://github.com/gosha20777/try-nix-os/releases`
   - Апстрима: `https://github.com/omacom/try-omarchy/releases`
   и перетащить приложение в `/Applications`. Диск ВМ при этом останется нетронутым.

### 7.3. Что делать, если контекст патча не совпал
В нашем случае проверка показала **100% совпадение контекста (0 rejected hunks)**.
Если при будущих обновлениях апстрима номера строк сдвинутся:
- Для `vrend_shader.c`: в функции генерации заголовка расширений найдите цикл по `shader_req_table` и условие:
  ```c
  if (shader_req_table[i].key == SHADER_REQ_SAMPLER_RECT && ctx->glsl_ver_required >= 140)
     continue;
  ```
  И добавьте аналогичную проверку для `SHADER_REQ_INSTANCE_ID`:
  ```c
  if (shader_req_table[i].key == SHADER_REQ_INSTANCE_ID && ctx->glsl_ver_required >= 140)
     continue;
  ```
- Для `vrend_renderer.c`: функция `vrend_report_shader_failure` и флаги `compile_failed` / `link_failed` в структуре `vrend_shader` заменяют вызовы `vrend_report_context_error(..., VIRGL_ERROR_CTX_ILLEGAL_SHADER, ...)` на пропуск отрисовки.

---

## 8. Приложение: ссылки на файлы и репозитории

### Репозитории
1. **Upstream (Try Omarchy)**:
   `https://github.com/omacom/try-omarchy`
2. **Форк пользователя (Try NixOS)**:
   `https://github.com/gosha20777/try-nix-os`
   - Скрипт сборки нативного runtime: `macos/build-qemu-gpu-runtime.sh`
   - Существующие патчи virglrenderer: `macos/patches/virgl-native-opengl.patch`, `macos/patches/virgl-ctx0-upload-flush.patch`
   - Скрипт запуска регрессионных тестов: `macos/Tests/virgl/run-regressions.py`
   - Корневой Makefile: `Makefile`
3. **OmacVM (источник патчей)**:
   `https://github.com/gillesgoetsch/OmacVM`
   - Патч `virgl-core-instance-id.patch`:
     `https://github.com/gillesgoetsch/OmacVM/blob/main/app/runtime/patches/virgl-core-instance-id.patch`
   - Патч `virgl-shader-failure-skip-draws.patch`:
     `https://github.com/gillesgoetsch/OmacVM/blob/main/app/runtime/patches/virgl-shader-failure-skip-draws.patch`
   - Хостовый тест компиляции шейдеров:
     `https://github.com/gillesgoetsch/OmacVM/blob/main/app/runtime/Tests/virgl/test-integer-sampler-shader.c`
   - Документация по архитектуре графики:
     `https://github.com/gillesgoetsch/OmacVM/blob/main/docs/architecture/graphics.md`
