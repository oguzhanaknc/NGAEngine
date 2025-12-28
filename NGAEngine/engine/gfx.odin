package engine

import "core:fmt"
import "core:log"
import "core:math/linalg/glsl"
import "core:mem"
import "core:os"
import "vendor:glfw"
import vk "vendor:vulkan"

// --- VERTEX YAPISI (Shader ile aynı olmalı) ---
Vertex :: struct {
	pos:   [2]f32,
	color: [3]f32,
	pad:   f32,
}

// Push Constant (Shader'a yollayacağımız paket)
PushConstantData :: struct {
	vertex_buffer_addr: u64, // Offset: 0  | Size: 8
	color:              [3]f32, // Offset: 8  | Size: 12
	_pad:               f32, // Offset: 20 | Size: 4  <-- HİZALAMA İÇİN
	offset:             [2]f32, // Offset: 24 | Size: 8
	transform:          glsl.mat2,
}

@(private)
frame_count: int = 0
// --- GLOBAL DEĞİŞKENLER (Private) ---
@(private)
g_instance: vk.Instance
@(private)
g_device: vk.Device
@(private)
g_physical_device: vk.PhysicalDevice
@(private)
g_surface: vk.SurfaceKHR
@(private)
g_graphics_queue: vk.Queue
@(private)
g_queue_family: u32
@(private)
g_vertex_addr: vk.DeviceAddress
@(private)
g_pipeline: vk.Pipeline
@(private)
g_pipeline_layout: vk.PipelineLayout
@(private)
g_vertex_buffer: vk.Buffer
@(private)
g_vertex_mem: vk.DeviceMemory
// Swapchain Durumu
@(private)
SwapchainCtx :: struct {
	handle:      vk.SwapchainKHR,
	format:      vk.Format,
	extent:      vk.Extent2D,
	images:      []vk.Image,
	image_views: []vk.ImageView,
}
@(private)
g_swapchain: SwapchainCtx
// Frame Verileri (Komutlar ve Senkronizasyon)
MAX_FRAMES_IN_FLIGHT :: 2
@(private)
FrameData :: struct {
	cmd_pool:            vk.CommandPool,
	cmd_buffer:          vk.CommandBuffer,
	image_available_sem: vk.Semaphore,
	render_finished_sem: vk.Semaphore,
	in_flight_fence:     vk.Fence,
}
@(private)
g_frames: [MAX_FRAMES_IN_FLIGHT]FrameData
@(private)
g_frame_index := 0


// Core.odin buradan çağıracak
gfx_init_vulkan :: proc(window: glfw.WindowHandle) -> bool {
	// Vulkan fonksiyonlarını yükle
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
	glfw_exts := glfw.GetRequiredInstanceExtensions()
	layers := []cstring{"VK_LAYER_KHRONOS_validation"}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &vk.ApplicationInfo {
			sType      = .APPLICATION_INFO,
			apiVersion = vk.API_VERSION_1_3, // Modern Vulkan
		},
		enabledExtensionCount   = u32(len(glfw_exts)),
		ppEnabledExtensionNames = raw_data(glfw_exts),
		// Debug modundaysan layer'ları aç, release ise kapat
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
	}

	vk_check(vk.CreateInstance(&create_info, nil, &g_instance))
	vk.load_proc_addresses_instance(g_instance)

	// 2. Surface
	if glfw.CreateWindowSurface(g_instance, window, nil, &g_surface) != .SUCCESS {
		log.error("Surface oluşturulamadı")
		return false
	}

	// 3. FİZİKSEL CİHAZ SEÇİMİ
	gpu_count: u32
	vk.EnumeratePhysicalDevices(g_instance, &gpu_count, nil)
	gpus := make([]vk.PhysicalDevice, gpu_count)
	defer delete(gpus)
	vk.EnumeratePhysicalDevices(g_instance, &gpu_count, raw_data(gpus))
	g_physical_device = gpus[0] // Basitçe ilkini alıyoruz (İleride discrete GPU seçimi eklenir)

	// 4. MANTIKSAL CİHAZ (DEVICE) OLUŞTURMA
	if !init_device() {return false}

	// 5. SWAPCHAIN OLUŞTURMA
	init_swapchain(window)

	// 6. KOMUT HAVUZLARI VE SENKRONİZASYON
	init_commands()
	// 7. PIPELINE VE BUFFER OLUŞTURMA
	init_pipeline()
	// Üçgen verisi
	vertices := []Vertex {
		// Pos (vec2)       // Color (vec3)       // Pad (f32)
		{{0.0, -0.5}, {1.0, 0.0, 0.0}, 0.0}, // Üst - Kırmızı
		{{0.5, 0.5}, {1.0, 0.0, 0.0}, 0.0}, // Sağ Alt - Yeşil
		{{-0.5, 0.5}, {1.0, 0.0, 0.0}, 0.0}, // Sol Alt - Mavi
	}
	triangle: Entity = create_entity()
	triangle2: Entity = create_entity({0.5, 0}, {0, 1.0, 0.0})
	triangle3: Entity = create_entity({0.8, 0}, {0, 0.0, 1.0})
	g_vertex_buffer, g_vertex_mem, g_vertex_addr = create_buffer_with_data(
		vertices,
		{.STORAGE_BUFFER},
	)
	log.info("Vulkan Grafik Motoru Hazır!")
	return true

}

gfx_shutdown :: proc() {
	// 1. GPU'nun işi bitirmesini bekle
	vk.DeviceWaitIdle(g_device)

	// 2. ÖNCE Kaynakları (Pipeline, Buffer, Memory) sil
	// Eğer Device'ı önce silersen, bunları silecek muhatap bulamazsın!
	vk.DestroyBuffer(g_device, g_vertex_buffer, nil)
	vk.FreeMemory(g_device, g_vertex_mem, nil)
	vk.DestroyPipeline(g_device, g_pipeline, nil)
	vk.DestroyPipelineLayout(g_device, g_pipeline_layout, nil)

	// 3. Frame Senkronizasyon Objelerini Sil
	for frame in g_frames {
		vk.DestroySemaphore(g_device, frame.image_available_sem, nil)
		vk.DestroySemaphore(g_device, frame.render_finished_sem, nil)
		vk.DestroyFence(g_device, frame.in_flight_fence, nil)
		vk.DestroyCommandPool(g_device, frame.cmd_pool, nil)
	}

	// 4. Swapchain Sil
	for view in g_swapchain.image_views do vk.DestroyImageView(g_device, view, nil)
	delete(g_swapchain.image_views)
	delete(g_swapchain.images)
	vk.DestroySwapchainKHR(g_device, g_swapchain.handle, nil)

	// 5. EN SON Cihazı (Device) Sil
	vk.DestroyDevice(g_device, nil)

	// 6. Surface ve Instance
	vk.DestroySurfaceKHR(g_instance, g_surface, nil)
	vk.DestroyInstance(g_instance, nil)

	log.info("Motor temiz bir şekilde kapatıldı.")
}

gfx_render_frame :: proc() {
	frame_count = (frame_count + 1) % 10000
	frame := &g_frames[g_frame_index]

	// 1. Bekle ve Resetle
	vk_check(vk.WaitForFences(g_device, 1, &frame.in_flight_fence, true, max(u64)))

	// 2. Resim İndeksini Al
	image_index: u32
	result := vk.AcquireNextImageKHR(
		g_device,
		g_swapchain.handle,
		max(u64),
		frame.image_available_sem,
		0,
		&image_index,
	)
	if result == .ERROR_OUT_OF_DATE_KHR {return}

	vk_check(vk.ResetFences(g_device, 1, &frame.in_flight_fence))
	vk_check(vk.ResetCommandBuffer(frame.cmd_buffer, {}))

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk_check(vk.BeginCommandBuffer(frame.cmd_buffer, &begin_info))

	// --- BARİYER 1: RESMİ YAZMAYA HAZIRLA ---
	// Undefined -> Color Attachment Optimal
	current_image := g_swapchain.images[image_index]
	transition_image(frame.cmd_buffer, current_image, .UNDEFINED, .ATTACHMENT_OPTIMAL)

	// --- ÇİZİM BAŞLA ---
	clear_value := vk.ClearValue {
		color = {float32 = {0.0, 0.0, 0.0, 1.0}},
	} // Koyu Mavi
	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {extent = g_swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = g_swapchain.image_views[image_index],
			imageLayout = .ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = clear_value,
		},
	}

	vk.CmdBeginRendering(frame.cmd_buffer, &rendering_info)

	vk.CmdBindPipeline(frame.cmd_buffer, .GRAPHICS, g_pipeline)
	// 3. Viewport ve Scissor Ayarla (Dynamic State olduğu için ŞART)
	// Eğer bunları ayarlamazsan Vulkan 0x0 boyutuna çizmeye çalışır.
	viewport := vk.Viewport {
		0,
		0,
		f32(g_swapchain.extent.width),
		f32(g_swapchain.extent.height),
		0,
		1,
	}
	scissor := vk.Rect2D{{0, 0}, g_swapchain.extent}

	vk.CmdSetViewport(frame.cmd_buffer, 0, 1, &viewport)
	vk.CmdSetScissor(frame.cmd_buffer, 0, 1, &scissor)

	for obj in g_world.transforms {
		pc_data := PushConstantData {
			vertex_buffer_addr = u64(g_vertex_addr),
			offset             = obj.translation,
			color              = obj.color,
			transform          = obj.mat2,
		}

		vk.CmdPushConstants(
			frame.cmd_buffer,
			g_pipeline_layout,
			{.VERTEX, .FRAGMENT},
			0,
			size_of(PushConstantData),
			&pc_data,
		)
		// 4. Çiz (Hardcoded üçgen olduğu için 3 vertex istiyoruz)
		vk.CmdDraw(frame.cmd_buffer, 3, 1, 0, 0)
	}

	// 5. Çizimi Bitir
	vk.CmdEndRendering(frame.cmd_buffer)

	// --- BARİYER 2: RESMİ SUNUMA HAZIRLA ---
	// Color Attachment Optimal -> Present Source
	transition_image(frame.cmd_buffer, current_image, .ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR)

	vk_check(vk.EndCommandBuffer(frame.cmd_buffer))

	// 3. Submit ve Present (Burası aynı)
	wait_stages := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &frame.image_available_sem,
		pWaitDstStageMask    = &wait_stages,
		commandBufferCount   = 1,
		pCommandBuffers      = &frame.cmd_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &frame.render_finished_sem,
	}

	vk_check(vk.QueueSubmit(g_graphics_queue, 1, &submit_info, frame.in_flight_fence))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &frame.render_finished_sem,
		swapchainCount     = 1,
		pSwapchains        = &g_swapchain.handle,
		pImageIndices      = &image_index,
	}
	vk.QueuePresentKHR(g_graphics_queue, &present_info)

	g_frame_index = (g_frame_index + 1) % MAX_FRAMES_IN_FLIGHT
}

@(private)
vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan Failure: {}", result, location = location)
}


@(private)
init_device :: proc() -> bool {
	// 1. Queue Ailesini Bul
	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(g_physical_device, &queue_count, nil)
	queues := make([]vk.QueueFamilyProperties, queue_count)
	defer delete(queues)
	vk.GetPhysicalDeviceQueueFamilyProperties(g_physical_device, &queue_count, raw_data(queues))

	found := false
	for q, i in queues {
		if .GRAPHICS in q.queueFlags {
			g_queue_family = u32(i)
			found = true
			break
		}
	}
	if !found {return false}


	// Vulkan 1.3 (Dynamic Rendering)
	features13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
	}

	// Vulkan 1.2 (Buffer Device Address & Bindless)
	features12 := vk.PhysicalDeviceVulkan12Features {
		sType                                     = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                                     = &features13, // Zincirleme
		bufferDeviceAddress                       = true, // <-- POINTER ERİŞİMİ
		descriptorIndexing                        = true,
		shaderSampledImageArrayNonUniformIndexing = true,
		runtimeDescriptorArray                    = true,
		scalarBlockLayout                         = true,
	}

	priority := f32(1.0)
	q_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = g_queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}

	exts := []cstring{"VK_KHR_swapchain"}

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features12, // Özellik zincirini bağla
		pQueueCreateInfos       = &q_info,
		queueCreateInfoCount    = 1,
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}

	if vk.CreateDevice(g_physical_device, &create_info, nil, &g_device) != .SUCCESS {
		log.error("Device oluşturulamadı!")
		return false
	}

	vk.GetDeviceQueue(g_device, g_queue_family, 0, &g_graphics_queue)
	return true
}

@(private)
init_swapchain :: proc(window: glfw.WindowHandle) {
	// (Adım 3'teki kodun basitleştirilmiş hali)
	// Yüzey formatı ve boyutunu al
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g_physical_device, g_surface, &caps)

	// Şimdilik sabit ayarlar (Hızlandırmak için)
	g_swapchain.extent = caps.currentExtent
	g_swapchain.format = .B8G8R8A8_SRGB
	composite_alpha := vk.CompositeAlphaFlagKHR.OPAQUE
	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = g_surface,
		minImageCount    = 2, // Double buffering
		imageFormat      = g_swapchain.format,
		imageColorSpace  = .SRGB_NONLINEAR,
		imageExtent      = g_swapchain.extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = caps.currentTransform,
		compositeAlpha   = {vk.CompositeAlphaFlagKHR.OPAQUE},
		presentMode      = .FIFO, // V-Sync
		clipped          = true,
	}

	vk_check(vk.CreateSwapchainKHR(g_device, &create_info, nil, &g_swapchain.handle))

	// Resimleri al
	count: u32
	vk.GetSwapchainImagesKHR(g_device, g_swapchain.handle, &count, nil)
	g_swapchain.images = make([]vk.Image, count)
	vk.GetSwapchainImagesKHR(g_device, g_swapchain.handle, &count, raw_data(g_swapchain.images))

	// View'ları oluştur
	g_swapchain.image_views = make([]vk.ImageView, count)
	for i in 0 ..< count {
		v_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = g_swapchain.images[i],
			viewType = .D2,
			format = g_swapchain.format,
			components = {.R, .G, .B, .A},
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk_check(vk.CreateImageView(g_device, &v_info, nil, &g_swapchain.image_views[i]))
	}
}

@(private)
init_commands :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		// Pool
		p_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = g_queue_family,
		}
		vk_check(vk.CreateCommandPool(g_device, &p_info, nil, &g_frames[i].cmd_pool))

		// Buffer
		a_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = g_frames[i].cmd_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}
		vk_check(vk.AllocateCommandBuffers(g_device, &a_info, &g_frames[i].cmd_buffer))

		// Sync
		s_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		f_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}

		vk_check(vk.CreateSemaphore(g_device, &s_info, nil, &g_frames[i].image_available_sem))
		vk_check(vk.CreateSemaphore(g_device, &s_info, nil, &g_frames[i].render_finished_sem))
		vk_check(vk.CreateFence(g_device, &f_info, nil, &g_frames[i].in_flight_fence))
	}
}
// Resmin formatını (layout) değiştiren yardımcı fonksiyon
@(private)
transition_image :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
) {

	barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	source_stage: vk.PipelineStageFlags
	destination_stage: vk.PipelineStageFlags

	// 1. Durum: Henüz hiçbir şey yok (Undefined) -> Boyamaya Hazırla (Color Attachment)
	if old_layout == .UNDEFINED && new_layout == .ATTACHMENT_OPTIMAL {
		barrier.srcAccessMask = {} // Öncesinde erişim yok
		barrier.dstAccessMask = {.COLOR_ATTACHMENT_WRITE} // Yazma izni istiyoruz
		source_stage = {.TOP_OF_PIPE}
		destination_stage = {.COLOR_ATTACHMENT_OUTPUT}
	} else if old_layout == .ATTACHMENT_OPTIMAL && new_layout == .PRESENT_SRC_KHR {
		barrier.srcAccessMask = {.COLOR_ATTACHMENT_WRITE} // Yazma bitmiş olmalı
		barrier.dstAccessMask = {} // Okuma izni (Present motoru halleder)
		source_stage = {.COLOR_ATTACHMENT_OUTPUT}
		destination_stage = {.BOTTOM_OF_PIPE}
	} else {
		log.error("Desteklenmeyen layout geçişi!")
	}

	vk.CmdPipelineBarrier(
		cmd,
		source_stage,
		destination_stage,
		{}, // Dependency flags
		0,
		nil, // Memory barriers
		0,
		nil, // Buffer barriers
		1,
		&barrier, // Image barriers
	)
}


@(private)
create_buffer_with_data :: proc(
	data: []Vertex,
	usage: vk.BufferUsageFlags,
) -> (
	vk.Buffer,
	vk.DeviceMemory,
	vk.DeviceAddress,
) {
	size := vk.DeviceSize(len(data) * size_of(Vertex))

	// 1. Buffer Oluştur
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage | {.SHADER_DEVICE_ADDRESS}, // <-- Pointer almak için ŞART
		sharingMode = .EXCLUSIVE,
	}

	buffer: vk.Buffer
	vk_check(vk.CreateBuffer(g_device, &buffer_info, nil, &buffer))

	// 2. Bellek Gereksinimlerini Sor
	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_device, buffer, &mem_reqs)

	// 3. Bellek Tipi Bul (Host Visible = CPU yazabilir, Coherent = GPU anında görür)
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(g_physical_device, &mem_props)

	mem_type_index: u32 = 999
	required_props := vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}

	for i in 0 ..< mem_props.memoryTypeCount {
		if (mem_reqs.memoryTypeBits & (1 << i) != 0) &&
		   (mem_props.memoryTypes[i].propertyFlags & required_props == required_props) {
			mem_type_index = i
			break
		}
	}
	if mem_type_index == 999 do log.panic("Uygun bellek tipi bulunamadı!")

	// 4. Bellek Ayır (Allocate) - BDA için allocate bayrağı önemli!
	alloc_flags := vk.MemoryAllocateFlagsInfo {
		sType = .MEMORY_ALLOCATE_FLAGS_INFO,
		flags = {.DEVICE_ADDRESS},
	}

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &alloc_flags,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type_index,
	}

	mem_dev: vk.DeviceMemory
	vk_check(vk.AllocateMemory(g_device, &alloc_info, nil, &mem_dev))

	// 5. Buffer ile Belleği Bağla
	vk_check(vk.BindBufferMemory(g_device, buffer, mem_dev, 0))

	// 6. Veriyi Kopyala (Mapping)
	data_ptr: rawptr
	vk_check(vk.MapMemory(g_device, mem_dev, 0, size, {}, &data_ptr))

	mem.copy(data_ptr, raw_data(data), int(size))
	vk.UnmapMemory(g_device, mem_dev)

	// 7. POINTER'I AL (Buffer Device Address)
	addr_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = buffer,
	}
	address := vk.GetBufferDeviceAddress(g_device, &addr_info)

	return buffer, mem_dev, address
}
@(private)
init_pipeline :: proc() {
	// 1. Shader'ları Yükle
	vert_code, _ := os.read_entire_file("shaders/triangle.vert.spv")
	frag_code, _ := os.read_entire_file("shaders/triangle.frag.spv")
	defer delete(vert_code)
	defer delete(frag_code)

	vert_module, frag_module: vk.ShaderModule
	v_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(vert_code),
		pCode    = cast(^u32)raw_data(vert_code),
	}
	f_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(frag_code),
		pCode    = cast(^u32)raw_data(frag_code),
	}

	vk_check(vk.CreateShaderModule(g_device, &v_info, nil, &vert_module))
	vk_check(vk.CreateShaderModule(g_device, &f_info, nil, &frag_module))
	defer vk.DestroyShaderModule(g_device, vert_module, nil)
	defer vk.DestroyShaderModule(g_device, frag_module, nil)

	// 2. Pipeline Layout (Push Constant Tanımı Burada!)
	pc_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset     = 0,
		size       = size_of(PushConstantData), // u64 boyutunda (8 byte)
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pc_range,
	}
	vk_check(vk.CreatePipelineLayout(g_device, &layout_info, nil, &g_pipeline_layout))

	// 3. Pipeline Aşamaları
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert_module,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = frag_module,
			pName = "main",
		},
	}

	// Dynamic Rendering Formatı
	color_format := g_swapchain.format
	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format,
	}

	// Vertex Input State: ARTIK BOŞ! Çünkü veriyi Pulling ile çekiyoruz.
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		lineWidth   = 1.0,
		cullMode    = {},
		frontFace   = .CLOCKWISE,
		polygonMode = .FILL,
	}
	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	// Blend (Karıştırma) Modu
	blend_att := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable    = false,
	}
	color_blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_att,
	}

	// Dinamik Durumlar (Viewport ve Scissor'ı çalışma anında değiştirebilelim)
	dyn_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dyn_states)),
		pDynamicStates    = raw_data(dyn_states),
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info, // <-- Dynamic Rendering buraya bağlanır
		stageCount          = 2,
		pStages             = raw_data(stages[:]),
		pVertexInputState   = &vertex_input, // <-- İçi boş!
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blend,
		pDynamicState       = &dynamic_state,
		layout              = g_pipeline_layout,
	}

	vk_check(vk.CreateGraphicsPipelines(g_device, 0, 1, &pipeline_info, nil, &g_pipeline))
}
