package main

import "NGAEngine:engine"
import "core:log"

main :: proc() {
	app_config := engine.Application {
		window_title  = "NGA Engine - Pro Mimarisi",
		window_width  = 1280,
		window_height = 720,
		on_init       = oyun_baslat,
		on_update     = oyun_guncelle,
		on_shutdown   = oyun_kapat,
	}
	engine.run(app_config)
}
oyun_kapat :: proc() {
	log.info("Oyun saved...")
}
oyun_guncelle :: proc(dt: f32) {
	log.infof("frame rate: %.4f ms (FPS: %.1f)", dt * 1000.0, 1.0 / dt)
}
oyun_baslat :: proc() -> bool {
	log.info("game assets loading...")

	return true
}
