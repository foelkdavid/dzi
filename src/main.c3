module dzi;
import std::math, std::core::string, std::io, std::sort;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys, bmu::image;

// dzi - display ze images. One image, centered and fitted; Left/Right walk the folder (neighbours are decoded
// in the background, so switching is instant); Ctrl+S shows the folder strip at the bottom.

const int MAX_IMAGES = 8192;
const int SLOTS = 3;           // current + next + previous, each with its own decoder
const float BAR_H = 44;
const float CELL_W = 220;

struct Slot
{
	int index;                 // image index held (or being decoded); -1 = free
	image::Loader loader;
	rl::RLTexture2D tex;
	bool loaded;
	image::Status status;
	int width;
	int height;
}

char[4096] folder;
sys::Entry[MAX_IMAGES] images;
int count;
int cur;
Slot[SLOTS] slots;
bool bar;
float zoom = 1;                // on top of "fit"
rl::RLVector2 pan;             // image centre offset from the view centre, logical px
float strip_scroll;
bool panning;
rl::RLVector2 pan_from;

fn bool is_image(String name)
{
	return txt::iends_with(name, ".png") || txt::iends_with(name, ".jpg") || txt::iends_with(name, ".jpeg")
		|| txt::iends_with(name, ".bmp") || txt::iends_with(name, ".gif");
}

fn int by_name(sys::Entry* a, sys::Entry* b) => txt::natcmp(txt::view(&a.name), txt::view(&b.name));

<* List the folder's images once (natural order) and find `name`. *>
fn void scan(String dir, String name) => @pool()
{
	sys::Entry[] all = mem::talloc_array(sys::Entry, MAX_IMAGES);
	int n = sys::list_dir(dir, all, false);
	count = 0;
	for (int i = 0; i < n && count < MAX_IMAGES; i++)
	{
		if (!all[i].dir && is_image(txt::view(&all[i].name))) images[count++] = all[i];
	}
	sort::quicksort(images[:count], &by_name);
	cur = 0;
	for (int i = 0; i < count; i++) if (txt::view(&images[i].name) == name) { cur = i; break; }
}

fn String path_of(int i) => txt::join(txt::view(&folder), txt::view(&images[i].name));

fn int wrap(int i) => count ? (i % count + count) % count : 0;

<* Keep current, next and previous decoded; reuse slots that already hold one of them. *>
fn void want() => @pool()
{
	if (!count) return;
	int[SLOTS] wanted = { cur, wrap(cur + 1), wrap(cur - 1) };
	foreach (wi : wanted)
	{
		bool held;
		foreach (&s : slots) if (s.index == wi) held = true;
		if (held) continue;
		foreach (&s : slots)
		{
			bool needed;
			foreach (x : wanted) if (s.index == x) needed = true;
			if (needed) continue;
			if (s.loaded) { rl::unload_texture(s.tex); s.loaded = false; }
			s.index = wi;
			s.status = READY;
			s.loader.limits = { .max_edge = image::MAX_EDGE, .max_file_bytes = 128 * 1024 * 1024, .max_pixels = 64 * 1000 * 1000 };
			if (!s.loader.request(path_of(wi))) s.status = READ_ERROR;
			break;
		}
	}
}

<* Upload finished decodes (GL on the UI thread only); mipmaps keep downscaled photos smooth. *>
fn void poll()
{
	foreach (&s : slots)
	{
		image::Result r;
		if (!s.loader.take(&r)) continue;
		s.status = r.status;
		if (r.status != READY) continue;
		s.tex = rl::load_texture_from_image(r.pixels);
		rl::unload_image(r.pixels);
		rl::gen_texture_mipmaps(&s.tex);
		s.tex.set_filter(rl::RLTextureFilter.TRILINEAR);
		s.width = r.width;
		s.height = r.height;
		s.loaded = s.tex.id != 0;
	}
}

fn Slot* current()
{
	if (!count) return null;
	foreach (&s : slots) if (s.index == cur) return s;
	return null;
}

fn void show(int i) => @pool()
{
	if (!count) return;
	cur = wrap(i);
	zoom = 1;
	pan = { 0, 0 };
	want();
	rl::set_window_title(string::tformat("%s - dzi", txt::view(&images[cur].name)).zstr_tcopy());
}

fn int main(String[] args)
{
	String target = ".";
	for (usz i = 1; i < args.len; i++)
	{
		switch (args[i])
		{
			case "--shot": case "--frames": case "--scale": i++;
			case "--help": case "-h":
				io::printn("Usage: dzi [IMAGE | FOLDER]\nLeft/Right: previous/next image in the folder; Home/End: first/last.\nCtrl+S: folder strip. Ctrl +/-/0 or wheel: zoom image (0 = fit); drag: pan. Ctrl+Shift +/-/0: interface zoom.\nq / Escape: quit.");
				return 0;
			default: target = args[i];
		}
	}
	foreach (&s : slots) s.index = -1;
	// Folder listing and the first decode start before the window: decoding overlaps window creation.
	@pool()
	{
		char[4096] real;
		sys::realpath(&real, target);
		String p = txt::view(&real);
		if (sys::is_dir(p)) { txt::set(&folder, p); scan(p, ""); }
		else { txt::set(&folder, txt::dirname(p)); scan(txt::dirname(p), txt::basename(p)); }
	};
	want();
	ui::open("dzi", 1200, 800, 320, 240);
	ui::zoom_shift_only = true;
	ui::clear_color = ui::BG_HARD;
	defer ui::close();
	defer { foreach (&s : slots) { s.loader.close(); if (s.loaded) rl::unload_texture(s.tex); } }
	ui::app_args(args);
	show(cur);
	while (ui::running()) frame();
	return 0;
}

fn void frame() => @pool()
{
	ui::frame_begin();
	poll();
	float w = ui::sw();
	float h = ui::sh();
	float view_h = bar ? h - BAR_H : h;
	rl::RLVector2 mouse = rl::get_mouse_position();
	if (ui::ctrl_down() && ui::letter('s')) bar = !bar;
	if (!ui::ctrl_down())
	{
		if (ui::repeat(rl::RLKeyboardKey.RIGHT)) show(cur + 1);
		if (ui::repeat(rl::RLKeyboardKey.LEFT)) show(cur - 1);
		if (rl::is_key_pressed(rl::RLKeyboardKey.HOME)) show(0);
		if (rl::is_key_pressed(rl::RLKeyboardKey.END)) show(count - 1);
		if (ui::letter('q') || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) ui::quit = true;
	}
	// Image zoom: Ctrl +/-/0 around the centre, the wheel around the pointer.
	float factor = 1;
	rl::RLVector2 at = { w / 2, view_h / 2 };
	if (ui::ctrl_down() && !ui::shift_down())
	{
		int step = ui::zoom_step();
		if (step > 0) factor = 1.25f;
		if (step < 0) factor = 0.8f;
		if (rl::is_key_pressed(rl::RLKeyboardKey.ZERO)) { zoom = 1; pan = { 0, 0 }; }
	}
	float wheel = rl::get_mouse_wheel_move();
	if (wheel != 0 && mouse[1] < view_h) { factor = wheel > 0 ? 1.15f : 1 / 1.15f; at = mouse; }
	if (factor != 1)
	{
		float nz = math::clamp(zoom * factor, 0.05f, 64.0f);
		float r = nz / zoom;
		// Keep the image point under `at` in place.
		float px = at[0] - w / 2;
		float py = at[1] - view_h / 2;
		pan = { px - (px - pan[0]) * r, py - (py - pan[1]) * r };
		zoom = nz;
	}
	// Drag to pan.
	if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) && mouse[1] < view_h) { panning = true; pan_from = mouse; }
	if (!rl::is_mouse_button_down(rl::RLMouseButton.LEFT)) panning = false;
	if (panning)
	{
		pan = { pan[0] + mouse[0] - pan_from[0], pan[1] + mouse[1] - pan_from[1] };
		pan_from = mouse;
	}

	Slot* s = current();
	if (!count)
	{
		ui::text("No images here (PNG, JPEG, BMP, GIF)", 24, 24, 18, ui::GRAY);
	}
	else if (s && s.loaded)
	{
		// Fit inside the view without enlarging past 1 texel = 1 physical pixel, then the user zoom.
		float sc = ui::scale;
		float fit = math::min(1.0f, math::min(w * sc / (float)s.tex.width, view_h * sc / (float)s.tex.height));
		float dw = (float)s.tex.width * fit * zoom / sc;
		float dh = (float)s.tex.height * fit * zoom / sc;
		Rect dst = { w / 2 + pan[0] - dw / 2, view_h / 2 + pan[1] - dh / 2, dw, dh };
		rl::draw_texture_pro(s.tex, { 0, 0, (float)s.tex.width, (float)s.tex.height }, dst, { 0, 0 }, 0, rl::WHITE);
	}
	else if (s && s.status != READY)
	{
		String why = s.status == TOO_LARGE ? "too large" : s.status == INVALID_IMAGE ? "not a readable image" : s.status == NO_MEMORY ? "out of memory" : "cannot be read";
		ui::text_fit(string::tformat("%s: %s", txt::view(&images[cur].name), why), 24, 24, w - 48, 16, ui::RED);
	}
	if (bar && count) draw_strip(w, h);
	ui::frame_end();
}

<* Folder strip: fixed-width cells, only the visible ones are drawn; the current image stays in view. *>
fn void draw_strip(float w, float h) => @pool()
{
	Rect area = { 0, h - BAR_H, w, BAR_H };
	ui::panel(area, ui::BG);
	ui::hline(0, h - BAR_H, w, ui::BG2);
	float content = (float)count * CELL_W;
	float cx = (float)cur * CELL_W;
	if (cx < strip_scroll) strip_scroll = cx;
	if (cx + CELL_W > strip_scroll + w) strip_scroll = cx + CELL_W - w;
	strip_scroll = math::clamp(strip_scroll, 0.0f, math::max(0.0f, content - w));
	int first = (int)(strip_scroll / CELL_W);
	int end = math::min(count, first + (int)(w / CELL_W) + 2);
	for (int i = first; i < end; i++)
	{
		Rect cell = { (float)i * CELL_W - strip_scroll + 4, h - BAR_H + 6, CELL_W - 8, BAR_H - 12 };
		if (i == cur) { ui::panel(cell, ui::BG2, 4); }
		else if (ui::hover(cell)) { ui::panel(cell, ui::BG1, 4); }
		ui::text_fit(txt::view(&images[i].name), cell.x + 10, cell.y + 8, cell.width - 20, 15, i == cur ? ui::FG : ui::FG4);
		if (ui::clicked(cell)) show(i);
	}
	Slot* s = current();
	String pos = s && s.loaded ? string::tformat("%d / %d · %d × %d", cur + 1, count, s.width, s.height) : string::tformat("%d / %d", cur + 1, count);
	float pw = ui::text_w(pos, 13) + 16;
	ui::panel({ w - pw - 8, h - BAR_H - 26, pw, 22 }, ui::BG, 4);
	ui::text(pos, w - pw, h - BAR_H - 22, 13, ui::FG4);
}
