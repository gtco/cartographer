local cartographer = {}

-- splits a path into directory, file (with filename), and just filename
-- i really only need the directory
-- https://stackoverflow.com/a/12191225
local function splitPath(path)
    return string.match(path, '(.-)([^\\/]-%.?([^%.\\/]*))$')
end

-- joins two paths together into a reasonable path that Lua can use.
-- handles going up a directory using ..
-- https://github.com/karai17/Simple-Tiled-Implementation/blob/master/sti/utils.lua#L5
local function formatPath(path)
	local npGen1, npGen2 = '[^SEP]+SEP%.%.SEP?', 'SEP+%.?SEP'
	local npPat1, npPat2 = npGen1:gsub('SEP', '/'), npGen2:gsub('SEP', '/')
	local k
	repeat path, k = path:gsub(npPat2, '/') until k == 0
	repeat path, k = path:gsub(npPat1, '') until k == 0
	if path == '' then path = '.' end
	return path
end

-- given a grid with w items per row, return the column and row of the nth item
-- (going from left to right, top to bottom)
-- https://stackoverflow.com/a/9816217
local function indexToCoordinates(n, w)
	return (n - 1) % w, math.floor((n - 1) / w)
end

local function coordinatesToIndex(x, y, w)
	return x + w * y + 1
end

local getByNameMetatable = {
	__index = function(self, key)
		for _, item in ipairs(self) do
			if item.name == key then return item end
		end
		return rawget(self, key)
	end,
}

local function getLayer(self, ...)
	local numberOfArguments = select('#', ...)
	if numberOfArguments == 0 then
		error('must specify at least one layer name', 2)
	end
	local layer
	local layerName = select(1, ...)
	if not self.layers[layerName] then return end
	layer = self.layers[layerName]
	for i = 2, numberOfArguments do
		layerName = select(i, ...)
		if not (layer.layers and layer.layers[layerName]) then return end
		layer = layer.layers[layerName]
	end
	return layer
end

local Layer = {}

-- A common class for all layer types.
Layer.base = {}
Layer.base.__index = Layer.base

function Layer.base:_init(map)
	self._map = map
end

-- Converts grid coordinates to pixel coordinates for this layer.
function Layer.base:gridToPixel(x, y)
	x, y = x * self._map.tilewidth, y * self._map.tileheight
	x, y = x + self.offsetx, y + self.offsety
	return x, y
end

-- Converts pixel coordinates for this layer to grid coordinates.
function Layer.base:pixelToGrid(x, y)
	x, y = x - self.offsetx, y - self.offsety
	x, y = x / self._map.tilewidth, y / self._map.tileheight
	x, y = math.floor(x), math.floor(y)
	return x, y
end

-- Represents a tile layer in an exported Tiled map.
Layer.tilelayer = setmetatable({}, Layer.base)
Layer.tilelayer.__index = Layer.tilelayer

function Layer.tilelayer:_initAnimations()
	self._animations = {}
	for _, tileset in ipairs(self._map.tilesets) do
		for _, tile in ipairs(tileset.tiles) do
			if tile.animation then
				local gid = tileset.firstgid + tile.id
				self._animations[gid] = {
					frames = tile.animation,
					currentFrame = 1,
					timer = tile.animation[1].duration,
				}
			end
		end
	end
end

function Layer.tilelayer:_createSpriteBatches()
	self._spriteBatches = {}
	for _, tileset in ipairs(self._map.tilesets) do
		if tileset.image then
			local image = self._map._images[tileset.image]
			self._spriteBatches[tileset] = love.graphics.newSpriteBatch(image)
		end
	end
end

function Layer.tilelayer:_init(map)
	Layer.base._init(self, map)
	self:_initAnimations()
	self:_createSpriteBatches()
	self._sprites = {}
	self._unbatchedItems = {}
	for _, gid, gridX, gridY, pixelX, pixelY in self:getTiles() do
		local tileset = self._map:getTileset(gid)
		if tileset.image then
			local quad = self._map:_getTileQuad(gid)
			table.insert(self._sprites, {
				tileGid = gid,
				gridX = gridX,
				gridY = gridY,
				pixelX = pixelX,
				pixelY = pixelY,
				id = self._spriteBatches[tileset]:add(quad, pixelX, pixelY),
			})
		else
			-- remember which items aren't part of a sprite batch
			-- so we can iterate through them in layer.draw
			table.insert(self._unbatchedItems, {
				gid = gid,
				gridX = gridX,
				gridY = gridY,
				pixelX = pixelX,
				pixelY = pixelY,
			})
		end
	end
end

function Layer.tilelayer:getGridBounds()
	if self.chunks then
		local left, top, right, bottom
		for _, chunk in ipairs(self.chunks) do
			local chunkLeft = chunk.x
			local chunkTop = chunk.y
			local chunkRight = chunk.x + chunk.width - 1
			local chunkBottom = chunk.y + chunk.height - 1
			if not left or chunkLeft < left then left = chunkLeft end
			if not top or chunkTop < top then top = chunkTop end
			if not right or chunkRight > right then right = chunkRight end
			if not bottom or chunkBottom > bottom then bottom = chunkBottom end
		end
		return left, top, right, bottom
	end
	return self.x, self.y, self.x + self.width - 1, self.y + self.height - 1
end

function Layer.tilelayer:getPixelBounds()
	local left, top, right, bottom = self:getGridBounds()
	left, top = self:gridToPixel(left, top)
	right, bottom = self:gridToPixel(right, bottom)
	return left, top, right, bottom
end

function Layer.tilelayer:getTileAtGridPosition(x, y)
	local gid
	if self.chunks then
		for _, chunk in ipairs(self.chunks) do
			local pointInChunk = x >= chunk.x
							 and x < chunk.x + chunk.width
							 and y >= chunk.y
							 and y < chunk.y + chunk.height
			if pointInChunk then
				gid = chunk.data[coordinatesToIndex(x - chunk.x, y - chunk.y, chunk.width)]
			end
		end
	else
		gid = self.data[coordinatesToIndex(x, y, self.width)]
	end
	if gid == 0 then return false end
	return gid
end

function Layer.tilelayer:setTileAtGridPosition(x, y, gid)
	if self.chunks then
		for _, chunk in ipairs(self.chunks) do
			local pointInChunk = x >= chunk.x
							 and x < chunk.x + chunk.width
							 and y >= chunk.y
							 and y < chunk.y + chunk.height
			if pointInChunk then
				local index = coordinatesToIndex(x - chunk.x, y - chunk.y, chunk.width)
				chunk.data[index] = gid
			end
		end
	else
		self.data[coordinatesToIndex(x, y, self.width)] = gid
	end
end

function Layer.tilelayer:getTileAtPixelPosition(x, y)
	return self:getTileAtGridPosition(self:pixelToGrid(x, y))
end

function Layer.tilelayer:setTileAtPixelPosition(gridX, gridY, gid)
	local pixelX, pixelY = self:pixelToGrid(gridX, gridY)
	return self:setTileAtGridPosition(pixelX, pixelY, gid)
end

function Layer.tilelayer:_getTileAtIndex(index)
	-- for infinite maps, treat all the chunk data like one big array
	if self.chunks then
		for _, chunk in ipairs(self.chunks) do
			if index <= #chunk.data then
				local gid = chunk.data[index]
				local gridX, gridY = indexToCoordinates(index, chunk.width)
				gridX, gridY = gridX + chunk.x, gridY + chunk.y
				local pixelX, pixelY = self:gridToPixel(gridX, gridY)
				return gid, gridX, gridY, pixelX, pixelY
			else
				index = index - #chunk.data
			end
		end
	elseif self.data[index] then
		local gid = self.data[index]
		local gridX, gridY = indexToCoordinates(index, self.width)
		local pixelX, pixelY = self:gridToPixel(gridX, gridY)
		return gid, gridX, gridY, pixelX, pixelY
	end
end

function Layer.tilelayer:_tileIterator(i)
	while true do
		i = i + 1
		local gid, gridX, gridY, pixelX, pixelY = self:_getTileAtIndex(i)
		if not gid then break end
		if gid ~= 0 then return i, gid, gridX, gridY, pixelX, pixelY end
	end
end

function Layer.tilelayer:getTiles()
	return self._tileIterator, self, 0
end

function Layer.tilelayer:_updateAnimations(dt)
	for gid, animation in pairs(self._animations) do
		-- decrement the animation timer
		animation.timer = animation.timer - 1000 * dt
		while animation.timer <= 0 do
			-- move to the next frame of animation
			animation.currentFrame = animation.currentFrame + 1
			if animation.currentFrame > #animation.frames then
				animation.currentFrame = 1
			end
			-- increment the animation timer by the duration of the new frame
			animation.timer = animation.timer + animation.frames[animation.currentFrame].duration
			-- update sprites
			local tileset = self._map:getTileset(gid)
			if tileset.image then
				local quad = self._map:_getTileQuad(gid, animation.currentFrame)
				for _, sprite in ipairs(self._sprites) do
					if sprite.tileGid == gid then
						self._spriteBatches[tileset]:set(sprite.id, quad, sprite.pixelX, sprite.pixelY)
					end
				end
			end
		end
	end
end

function Layer.tilelayer:update(dt)
	self:_updateAnimations(dt)
end

function Layer.tilelayer:draw()
	love.graphics.push()
	love.graphics.translate(self.offsetx, self.offsety)
	-- draw the sprite batches
	for _, spriteBatch in pairs(self._spriteBatches) do
		love.graphics.draw(spriteBatch)
	end
	-- draw the items that aren't part of a sprite batch
	for _, item in ipairs(self._unbatchedItems) do
		local tile = self._map:getTile(item.gid)
		love.graphics.draw(self._map._images[tile.image], item.pixelX, item.pixelY)
	end
	love.graphics.pop()
end

-- Represents an object layer in an exported Tiled map.
Layer.objectgroup = setmetatable({}, Layer.base)
Layer.objectgroup.__index = Layer.objectgroup

-- Represents an image layer in an exported Tiled map.
Layer.imagelayer = setmetatable({}, Layer.base)
Layer.imagelayer.__index = Layer.imagelayer

function Layer.imagelayer:draw()
	love.graphics.draw(self._map._images[self.image], self.offsetx, self.offsety)
end

-- Represents a layer group in an exported Tiled map.
Layer.group = setmetatable({}, Layer.base)
Layer.group.__index = Layer.group

function Layer.group:_init(map)
	Layer.base._init(self, map)
	for _, layer in ipairs(self.layers) do
		setmetatable(layer, Layer[layer.type])
		layer:_init(map)
	end
	setmetatable(self.layers, getByNameMetatable)
end

Layer.group.getLayer = getLayer

function Layer.group:update(dt)
	for _, layer in ipairs(self.layers) do
		if layer.update then layer:update(dt) end
	end
end

function Layer.group:draw()
	for _, layer in ipairs(self.layers) do
		if layer.visible and layer.draw then layer:draw() end
	end
end

local Map = {}
Map.__index = Map

-- Loads an image if it hasn't already been loaded yet.
-- Images are stored in map._images, and the key is the relative
-- path to the image.
function Map:_loadImage(relativeImagePath)
	if self._images[relativeImagePath] then return end
	local imagePath = formatPath(self.dir .. relativeImagePath)
	self._images[relativeImagePath] = love.graphics.newImage(imagePath)
end

-- Loads all of the images used by the map.
function Map:_loadImages()
	self._images = {}
	for _, tileset in ipairs(self.tilesets) do
		if tileset.image then self:_loadImage(tileset.image) end
		for _, tile in ipairs(tileset.tiles) do
			if tile.image then self:_loadImage(tile.image) end
		end
	end
	for _, layer in ipairs(self.layers) do
		if layer.type == 'imagelayer' then
			self:_loadImage(layer.image)
		end
	end
end

function Map:_initLayers()
	for _, layer in ipairs(self.layers) do
		setmetatable(layer, Layer[layer.type])
		layer:_init(self)
	end
	setmetatable(self.layers, getByNameMetatable)
end

function Map:_init(path)
	self.dir = splitPath(path)
	self:_loadImages()
	setmetatable(self.tilesets, getByNameMetatable)
	self:_initLayers()
end

-- Gets the quad of the tile with the given local ID.
function Map:_getTileQuad(gid, frame)
	frame = frame or 1
	local tileset = self:getTileset(gid)
	if not tileset.image then return false end
	local id = gid - tileset.firstgid
	local tile = self:getTile(gid)
	if tile and tile.animation then
		id = tile.animation[frame].tileid
	end
	local image = self._images[tileset.image]
	local gridWidth = math.floor(image:getWidth() / (tileset.tilewidth + tileset.spacing))
	local x, y = indexToCoordinates(id + 1, gridWidth)
	return love.graphics.newQuad(
		x * (tileset.tilewidth + tileset.spacing),
		y * (tileset.tileheight + tileset.spacing),
		tileset.tilewidth, tileset.tileheight,
		image:getWidth(), image:getHeight()
	)
end

-- Gets the tileset that has the tile with the given global ID.
function Map:getTileset(gid)
	for i = #self.tilesets, 1, -1 do
		local tileset = self.tilesets[i]
		if tileset.firstgid <= gid then
			return tileset
		end
	end
end

-- Gets the data table for the tile with the given global ID, if it exists.
function Map:getTile(gid)
	local tileset = self:getTileset(gid)
	for _, tile in ipairs(tileset.tiles) do
		if tileset.firstgid + tile.id == gid then
			return tile
		end
	end
end

-- Gets the value of the specified property on the tile
-- with the given global ID, if it exists.
function Map:getTileProperty(gid, propertyName)
	local tile = self:getTile(gid)
	if not tile then return end
	if not tile.properties then return end
	return tile.properties[propertyName]
end

-- Sets the value of the specified property on the tile
-- with the given global ID.
function Map:setTileProperty(gid, propertyName, propertyValue)
	local tile = self:getTile(gid)
	if not tile then
		local tileset = self:getTileset(gid)
		tile = {id = gid - tileset.firstgid}
		table.insert(tileset.tiles, tile)
	end
	tile.properties = tile.properties or {}
	tile.properties[propertyName] = propertyValue
end

Map.getLayer = getLayer

function Map:update(dt)
	for _, layer in ipairs(self.layers) do
		if layer.update then layer:update(dt) end
	end
end

function Map:drawBackground()
	if self.backgroundcolor then
		love.graphics.push 'all'
		local r = self.backgroundcolor[1] / 255
		local g = self.backgroundcolor[2] / 255
		local b = self.backgroundcolor[3] / 255
		love.graphics.setColor(r, g, b)
		love.graphics.rectangle('fill', 0, 0,
			self.width * self.tilewidth,
			self.height * self.tileheight)
		love.graphics.pop()
	end
end

function Map:draw()
	self:drawBackground()
	for _, layer in ipairs(self.layers) do
		if layer.visible and layer.draw then layer:draw() end
	end
end

-- Loads a Tiled map from a lua file.
function cartographer.load(path)
	if not path then error('No map path provided', 2) end
	local map = setmetatable(love.filesystem.load(path)(), Map)
	map:_init(path)
	return map
end

return cartographer
