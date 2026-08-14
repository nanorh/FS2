# Design tokens and style factories for the control panel.
#
# The palette is deliberately near-black so the panel reads as an
# extension of the simulation canvas rather than a separate chrome bar.
# Amber is the single accent, picked to echo the sand colour without
# colliding with the cool elements (water, ice, cryo).
class_name UITheme
extends RefCounted

# --- Surfaces ---------------------------------------------------------
const SURFACE := Color("101216")       # panel background
const RAISED := Color("1b1e25")        # controls at rest
const RAISED_HOVER := Color("252932")  # controls under the cursor
const SUNKEN := Color("0a0b0e")        # slider troughs, insets
const BORDER := Color("2a2e38")
const BORDER_SOFT := Color("1f232b")

# --- Text -------------------------------------------------------------
const TEXT := Color("e7e9ee")
const TEXT_DIM := Color("8b909c")
const TEXT_FAINT := Color("5a606c")

# --- Accents ----------------------------------------------------------
const ACCENT := Color("f0a93c")
const ACCENT_SOFT := Color("f0a93c33")
const DANGER := Color("e0625c")

# --- Geometry ---------------------------------------------------------
const R_SM := 5
const R_MD := 7
const R_LG := 10


static func box(bg: Color, radius: int, pad_h: int, pad_v: int,
		border_w := 0, border_c := Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	if border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border_c
	sb.anti_aliasing = true
	return sb


static func empty_box() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()


# A filled circle with an antialiased edge, used for element swatches
# and slider grabbers.
static func dot(color: Color, size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var centre := (size - 1) * 0.5
	var radius := size * 0.5 - 0.5
	for y in size:
		for x in size:
			var d := Vector2(x - centre, y - centre).length()
			var a := clampf(radius - d + 0.5, 0.0, 1.0)
			if a > 0.0:
				img.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	return ImageTexture.create_from_image(img)


enum { GLYPH_CIRCLE, GLYPH_SQUARE, GLYPH_SPRAY, GLYPH_FILL }


# Tool icons, drawn procedurally so the project stays asset-free.
static func glyph(kind: int, size: int, colour: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := (size - 1) * 0.5
	var r := size * 0.5 - 1.5

	match kind:
		GLYPH_CIRCLE:
			for y in size:
				for x in size:
					var d := Vector2(x - c, y - c).length()
					_put(img, x, y, colour, clampf(1.2 - absf(d - r), 0.0, 1.0))
		GLYPH_SQUARE:
			for y in size:
				for x in size:
					var d := maxf(absf(x - c), absf(y - c))
					_put(img, x, y, colour, clampf(1.2 - absf(d - r), 0.0, 1.0))
		GLYPH_SPRAY:
			# Fixed scatter so the icon is stable between runs. Balanced
			# about the centre and denser there, mirroring the falloff
			# the spray brush actually paints.
			var pts := [
				Vector2(0.0, 0.0), Vector2(-0.34, -0.2), Vector2(0.32, -0.26),
				Vector2(0.2, 0.3), Vector2(-0.26, 0.32), Vector2(0.0, -0.62),
				Vector2(-0.66, 0.06), Vector2(0.64, 0.1), Vector2(0.0, 0.66),
				Vector2(-0.56, -0.56), Vector2(0.58, -0.54), Vector2(-0.54, 0.58),
				Vector2(0.56, 0.56),
			]
			for pt in pts:
				var px := int(round(c + pt.x * r))
				var py := int(round(c + pt.y * r))
				var strength := 1.0 if pt.length() < 0.45 else 0.7
				_put(img, px, py, colour, strength)
		GLYPH_FILL:
			# Square outline with the lower half solid: a fill level.
			for y in size:
				for x in size:
					var d := maxf(absf(x - c), absf(y - c))
					var edge := clampf(1.2 - absf(d - r), 0.0, 1.0)
					var inside := 1.0 if (d < r and float(y) > c + 0.5) else 0.0
					_put(img, x, y, colour, maxf(edge, inside * 0.85))

	return ImageTexture.create_from_image(img)


static func _put(img: Image, x: int, y: int, colour: Color, a: float) -> void:
	if a <= 0.0 or x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	var prev := img.get_pixel(x, y)
	var na := maxf(prev.a, clampf(a, 0.0, 1.0))
	img.set_pixel(x, y, Color(colour.r, colour.g, colour.b, na))


# Small uppercase section heading.
static func caption(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", 9)
	l.add_theme_color_override("font_color", TEXT_FAINT)
	return l


# Generic control button (Clear / Save / Load, pen sizes, toggles).
# `tint` drives the pressed and hover treatment.
static func style_button(b: Button, tint: Color, font_size := 11) -> void:
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_stylebox_override("normal", box(RAISED, R_SM, 10, 5, 1, BORDER_SOFT))
	b.add_theme_stylebox_override("hover", box(RAISED_HOVER, R_SM, 10, 5, 1, BORDER))
	b.add_theme_stylebox_override("pressed",
		box(Color(tint.r, tint.g, tint.b, 0.20), R_SM, 10, 5, 1, tint))
	b.add_theme_stylebox_override("focus", empty_box())
	b.add_theme_color_override("font_color", TEXT_DIM)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", tint.lightened(0.35))
	b.add_theme_color_override("font_focus_color", TEXT)


# Borderless button: chrome only appears on hover or when active.
static func style_ghost(b: Button, tint: Color) -> void:
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 10)
	b.add_theme_stylebox_override("normal", box(Color(0, 0, 0, 0), R_SM, 8, 4))
	b.add_theme_stylebox_override("hover", box(RAISED_HOVER, R_SM, 8, 4))
	b.add_theme_stylebox_override("pressed",
		box(Color(tint.r, tint.g, tint.b, 0.16), R_SM, 8, 4))
	b.add_theme_stylebox_override("focus", empty_box())
	b.add_theme_color_override("font_color", TEXT_DIM)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", tint.lightened(0.3))


# Element swatch: a bare colour tile. The name lives in the tooltip and
# in the palette's heading, which keeps the grid free of text.
static func style_swatch(b: Button, colour: Color, is_empty := false) -> void:
	b.focus_mode = Control.FOCUS_NONE
	var fill := colour
	var rest_border := 0
	var rest_border_c := Color(0, 0, 0, 0)
	if is_empty:
		# The eraser paints BACKGROUND, whose colour is black; show it as
		# an outlined hole instead of an invisible tile.
		fill = SUNKEN
		rest_border = 1
		rest_border_c = TEXT_FAINT
	b.add_theme_stylebox_override("normal", box(fill, 4, 0, 0, rest_border, rest_border_c))
	b.add_theme_stylebox_override("hover",
		box(fill.lightened(0.12) if not is_empty else RAISED_HOVER, 4, 0, 0, 1, TEXT_DIM))
	b.add_theme_stylebox_override("pressed", box(fill, 4, 0, 0, 2, TEXT))
	b.add_theme_stylebox_override("focus", empty_box())


# Square icon button for the tool row.
static func style_tool(b: Button) -> void:
	b.focus_mode = Control.FOCUS_NONE
	# Button.icon_alignment defaults to LEFT, which parks the glyph off
	# centre in a fixed-size square button.
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.add_theme_stylebox_override("normal", box(Color(0, 0, 0, 0), R_SM, 0, 0))
	b.add_theme_stylebox_override("hover", box(RAISED_HOVER, R_SM, 0, 0))
	b.add_theme_stylebox_override("pressed",
		box(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18), R_SM, 0, 0, 1, ACCENT))
	b.add_theme_stylebox_override("focus", empty_box())
	# Glyphs are generated white and tinted per state, so a single
	# texture serves all three.
	b.add_theme_color_override("icon_normal_color", TEXT_DIM)
	b.add_theme_color_override("icon_hover_color", TEXT)
	b.add_theme_color_override("icon_pressed_color", ACCENT)


static func style_option(ob: OptionButton, font_size := 10) -> void:
	ob.focus_mode = Control.FOCUS_NONE
	ob.add_theme_font_size_override("font_size", font_size)
	ob.add_theme_stylebox_override("normal", box(RAISED, R_SM, 8, 4, 1, BORDER_SOFT))
	ob.add_theme_stylebox_override("hover", box(RAISED_HOVER, R_SM, 8, 4, 1, BORDER))
	ob.add_theme_stylebox_override("pressed", box(RAISED_HOVER, R_SM, 8, 4, 1, ACCENT))
	ob.add_theme_stylebox_override("focus", empty_box())
	ob.add_theme_color_override("font_color", TEXT)
	ob.add_theme_color_override("font_hover_color", Color.WHITE)

	var pop := ob.get_popup()
	pop.add_theme_stylebox_override("panel", box(RAISED, R_MD, 6, 6, 1, BORDER))
	pop.add_theme_stylebox_override("hover",
		box(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18), R_SM, 6, 3))
	pop.add_theme_color_override("font_color", TEXT_DIM)
	pop.add_theme_color_override("font_hover_color", Color.WHITE)
	pop.add_theme_font_size_override("font_size", font_size)


static func style_slider(s: HSlider) -> void:
	s.focus_mode = Control.FOCUS_NONE
	var trough := box(SUNKEN, 3, 0, 3, 1, BORDER_SOFT)
	s.add_theme_stylebox_override("slider", trough)
	s.add_theme_stylebox_override("grabber_area", box(ACCENT, 3, 0, 3))
	s.add_theme_stylebox_override("grabber_area_highlight",
		box(ACCENT.lightened(0.15), 3, 0, 3))
	var knob := dot(Color("f6f7f9"), 13)
	s.add_theme_icon_override("grabber", knob)
	s.add_theme_icon_override("grabber_highlight", dot(ACCENT.lightened(0.5), 15))


static func style_panel(p: PanelContainer) -> void:
	# The default panel stylebox is translucent, which lets the
	# simulation show through once the grid meets the panel edge.
	var sb := box(SURFACE, 0, 0, 0)
	sb.border_width_top = 1
	sb.border_color = BORDER
	p.add_theme_stylebox_override("panel", sb)


# Thin vertical rule between sections.
static func divider() -> Control:
	var line := Panel.new()
	line.custom_minimum_size = Vector2(1, 0)
	line.size_flags_vertical = Control.SIZE_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = BORDER_SOFT
	line.add_theme_stylebox_override("panel", sb)
	return line
