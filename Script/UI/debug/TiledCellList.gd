extends Node
class_name TiledCellList

class tile_data:
	extends RefCounted
	var tile_id: int
	var tiles: Array[TiledCell] = []	

var selected_tile_img: TextureRect = null
var tile_set: TileSet = null
var atlas_source: TileSetAtlasSource = null
var atlas_source_id: int = 0
var grass_forms_tiled: Dictionary = {}
var mytiles: Dictionary = {}
var tile_coord_list: Array[Dictionary] = []
var cur_select_tile_data: tile_data = null

func _ready():
	tile_set = preload("res://tiledmap/Tileset.tres")
	atlas_source = tile_set.get_source(atlas_source_id)
	init_tile_coord_list()
	init_scroll_list()
	$ScrollNode.refresh_scroll_panel(tile_coord_list)

func init_tile_coord_list():
	grass_forms_tiled = InfiniteTileMap._init_grass_forms_tiled()
	mytiles = InfiniteTileMap._init_grass_forms(grass_forms_tiled)
	
	# 全沙
	var _data = tile_data.new()
	_data.tile_id = -1
	_data.tiles.append_array([
		TiledCell.new(Vector2i(5, 10), 0, 1),
		TiledCell.new(Vector2i(5, 10), 0, 1),
		TiledCell.new(Vector2i(6, 10), 0, 1),
		TiledCell.new(Vector2i(6, 10), 0, 1)
	])
	tile_coord_list.append({"data": _data})

	for k in mytiles:
		var mytile = mytiles[k]
		var data = tile_data.new()
		data.tile_id = k
		if k == 0:
			data.tiles.append_array([
				mytile.cell[0][0],
				mytile.cell[0][1],
				mytile.cell[0][0],
				mytile.cell[0][1]
			])
		else:
			data.tiles.append_array([
				mytile.cell[0][0],
				mytile.cell[1][0],
				mytile.cell[2][0],
				mytile.cell[3][0]
			])
		tile_coord_list.append({"data": data})

func init_scroll_list():
	var scroll_list = $ScrollNode
	scroll_list.set_scroll_panel($ScrollNode/ScrollContainer)
	scroll_list.set_scroll_item($ScrollNode/ScrollItem)
	scroll_list.set_scroll_data_handler(_on_item_data)  
	scroll_list.set_item_spacing(0)
	scroll_list.set_vertical(false)


func _on_item_data(item: Control, datadict: Dictionary) -> void:	
	var data = datadict["data"]
	var tile_id = data.tile_id
	var tiles = data.tiles

	item.get_node("Name").text = str(tile_id)

	var cell_size: Vector2 = Vector2(16, 16) * 2
	var output_image = Image.create(cell_size.x, cell_size.y, false, Image.FORMAT_RGBA8)

	var texture_size = Vector2(288, 432)
	var idx = 0
	for i in data.tiles:
		# var tile_data: TileData = atlas_source.get_tile_data(i.assets_pos, 0)
		var rect = atlas_source.get_tile_texture_region(i.assets_pos, 0)
		var tile_image: Image = atlas_source.texture.get_image().get_region(rect)
		for j in range(i.dir):
			tile_image.rotate_90(0)
		var target_position: Vector2i = Vector2i(cell_size.x / 2 * (idx % 2), cell_size.y / 2 * (idx / 2))
		output_image.blit_rect(tile_image, Rect2i(Vector2i.ZERO, tile_image.get_size()), target_position)
		idx += 1

	var imgtext = ImageTexture.create_from_image(output_image)
	item.get_node("Image").set_texture(imgtext)
	item.get_node("Button").pressed.connect(_on_debug_draw_toggled.bind(data, item.get_node("Image")))

func _process(delta: float) -> void:
	if selected_tile_img:
		selected_tile_img.set_position(get_viewport().get_mouse_position())

func _on_debug_draw_toggled(data: tile_data, image_node: TextureRect):
	clear_cur_select()
	print("select tile: ", data.tile_id)
	cur_select_tile_data = data
	# 复制一个图像跟着鼠标
	selected_tile_img = image_node.duplicate(16)
	get_parent().add_child(selected_tile_img)
	selected_tile_img.set_mouse_filter(Control.MOUSE_FILTER_IGNORE)


func get_cur_select_tile_data() -> tile_data:
	return cur_select_tile_data

func clear_cur_select():
	cur_select_tile_data = null
	# 清除当前选中的 tile 图像
	if selected_tile_img:
		selected_tile_img.queue_free()
		selected_tile_img = null
