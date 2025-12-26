package engine
import "base:runtime"
import "core:log"
import "core:mem"
import "core:time"
import "vendor:glfw"
Application :: struct {
	window_title:  cstring,
	window_width:  i32,
	window_height: i32,
	on_init:       proc() -> bool, // Başlarken çalışacak
	on_update:     proc(dt: f32), // Her karede çalışacak (dt: geçen süre)
	on_shutdown:   proc(), // Kapanırken çalışacak
}
@(private = "file")
g_ctx: runtime.Context
@(private = "file")
window: glfw.WindowHandle


run :: proc(app: Application) {
	context.logger = log.create_console_logger()
	g_ctx = context
	glfw.SetErrorCallback(catch_error)
	if !glfw.Init() {
		log.fatal("GLFW error!")
		return
	}
	defer glfw.Terminate()
	// B. Pencere Oluşturma (Kullanıcının istediği ayarlarda) // Profesyonel dokunuş: Window hint'leri buraya eklenebilir (Resizable, Decorator vs.)
	glfw.WindowHint(glfw.RESIZABLE, 1)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	window = glfw.CreateWindow(app.window_width, app.window_height, app.window_title, nil, nil)
	if window == nil {
		log.fatal("window has not ben created!")
		return
	}
	log.info("Graphics System Started...")
	if !gfx_init_vulkan(window) {
		log.fatal("Vulkan error!")
		return
	}
	// Çıkarken Vulkan'ı temizle
	defer gfx_shutdown()
	log.info("Engine started. game loading...")
	// C. Kullanıcının Init Fonksiyonunu Çağır
	if app.on_init != nil {
		if !app.on_init() {
			log.error("game error (on_init false).")
			return
		}
	}
	// --- 3. ANA OYUN DÖNGÜSÜ (MAIN LOOP) ---
	// Zamanlayıcıyı başlat stopwatch:
	stopwatch: time.Stopwatch
	time.stopwatch_start(&stopwatch)
	for !glfw.WindowShouldClose(window) {
		duration := time.stopwatch_duration(stopwatch)
		time.stopwatch_reset(&stopwatch)
		time.stopwatch_start(&stopwatch)
		dt := f32(time.duration_seconds(duration)) // b. Olayları İşle
		glfw.PollEvents()
		free_all(context.temp_allocator)
		if app.on_update != nil {
			app.on_update(dt)
		}
		// e. Buffer Değişimi
		gfx_render_frame()
	}
	// D. Kapanış
	log.info("loop done. Exiting...")
	if app.on_shutdown != nil {app.on_shutdown()}
}

@(private = "file")
catch_error :: proc "c" (error: i32, description: cstring) {
	context = g_ctx; log.errorf("GLFW error [{}]: {}", error, description)
}
