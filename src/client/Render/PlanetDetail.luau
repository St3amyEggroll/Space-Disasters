--!strict
--[[
	PlanetDetail (CHANGED (Planet detail): Steamy: "when i am in orbit i feel like the planet is a small little planet
	by the level of detail on it, i think it needs to be more detailed from space")
	Pure per-tier settings and decisions for the scaled-space planets (Render/ScaledSpace), testable offline.

	Textures (EditableImage per patch, painted in the background):
	  * base: every patch of every body (24 patches per body). CHANGED (Memory budget): per tier: Earth 256 px on
	    High, 128 px on Medium / Low; the Mun 128 px on every tier
	  * detail slots: a few extra, sharper images that move to the patches nearest the camera's ground point
	    (desiredPatches) on the dominant body; a patch shows its slot image once painted and falls back to its base
	    image when the slot moves on. CHANGED (Memory budget): per tier and body (slotTexture / slotCount): High
	    4 x 512 px on Earth and 2 x 256 on the Mun, Medium 2 x 512 / 2 x 256, Low none (was High 8 x 1024, Medium
	    6 x 512, Low 2 x 512). From 10 km up a 512 px patch is ~92 m per pixel instead of ~184 m.
	  * clouds: a sparse wispy shell with alpha through MeshPart.TextureContent. CHANGED (Memory budget): High only,
	    128 px (was Medium 128 / High 256)
	All ground textures bake in the relief shade (Biome / BiomeDetail.reliefShade from Sim/Relief's heights).
	CHANGED (Memory budget): EditableImage bytes (RGBA, textureBytes: every base image + the largest body's slots
	+ clouds): Low 3.0 MiB, Medium 5.0 MiB, High 13.0 MiB (was 9.5 / 15 / 45.5 MB). Render/EditableBudget holds
	them with the terrain meshes under one per-tier ceiling: base images of the body the camera is near only while
	its proxy is drawn, detail slots and clouds give way first.

	Atmosphere: nested translucent shells; on the disc they add up to about the old single shell's tint, while
	beyond the limb fewer shells overlap the farther out you look, so the halo fades outward (pale near the ground,
	deeper blue above). Low keeps the single original shell.

	API:
		PlanetDetail.tierSpec(tier): TierSpec
		PlanetDetail.baseTexture(tier, bodyId): TextureSpec          CHANGED (Memory budget): per tier
		PlanetDetail.slotTexture(tier, bodyId): TextureSpec?        nil: no detail slots for that body
		PlanetDetail.slotCount(tier, bodyId): number                CHANGED (Memory budget): slots on that body
		PlanetDetail.cloudTexture(tier): TextureSpec?               nil: no clouds on this tier
		PlanetDetail.atmosphereLayers(tier): { AtmosphereLayer }    innermost first
		PlanetDetail.closeness(m, ux, uy, uz): number               cos of the angle from u to patch m (1 inside it)
		PlanetDetail.desiredPatches(rotations, ux, uy, uz, count): { number }   nearest patches to unit direction u
		PlanetDetail.slotsWanted(altitude, radius): boolean          is the camera low enough for detail slots
		PlanetDetail.cloudFade(altitude, handoverAltitude): number   0..1 cloud shell visibility
		PlanetDetail.textureBytes(tier): number                      EditableImage memory of a tier (bytes)
		PlanetDetail.imageBytes(spec): number                        CHANGED (Memory budget): one image's bytes
		PlanetDetail.CLOUD_SHELL_SCALE, PlanetDetail.MAX_SHELL_SCALE, PlanetDetail.ATMOSPHERE_MAX_LAYERS
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)

export type Tier = "Low" | "Medium" | "High"
export type TextureSpec = {
	size: number, -- pixels per patch side
	cells: number, -- Biome coarse grid cells per side
	detail: number, -- Biome detail level (octaves): 1 coarse, 3 = Biome.sample's full detail
}
-- CHANGED (Memory budget): the slot count moved to slotCount (per body)
export type TierSpec = {
	paintBudgetS: number, -- background painting work per frame (s)
	clouds: boolean,
}
export type AtmosphereLayer = { scale: number, transparency: number, color: Color3 }

--============================================================================
-- Tunables
--============================================================================
-- CHANGED (Memory budget): fewer / smaller images (the Editable memory budget, Render/EditableBudget); clouds High only
local TIERS: { [Tier]: TierSpec } = {
	Low = { paintBudgetS = 0.0025, clouds = false },
	Medium = { paintBudgetS = 0.0035, clouds = false },
	High = { paintBudgetS = 0.005, clouds = true },
}
local BASE_TEXTURES: { [Tier]: { [number]: TextureSpec } } = {
	Low = {
		[Bodies.HOMEWORLD] = { size = 128, cells = 32, detail = 1 },
		[Bodies.MOON] = { size = 128, cells = 32, detail = 1 },
	},
	Medium = {
		[Bodies.HOMEWORLD] = { size = 128, cells = 32, detail = 1 },
		[Bodies.MOON] = { size = 128, cells = 32, detail = 1 },
	},
	High = {
		[Bodies.HOMEWORLD] = { size = 256, cells = 64, detail = 1 },
		[Bodies.MOON] = { size = 128, cells = 32, detail = 1 },
	},
}
local DEFAULT_BASE_TEXTURE: TextureSpec = { size = 128, cells = 32, detail = 1 }
local SLOT_TEXTURES: { [Tier]: { [number]: TextureSpec } } = {
	Low = {},
	Medium = {
		[Bodies.HOMEWORLD] = { size = 512, cells = 128, detail = 2 },
		[Bodies.MOON] = { size = 256, cells = 64, detail = 2 },
	},
	High = {
		[Bodies.HOMEWORLD] = { size = 512, cells = 128, detail = 3 },
		[Bodies.MOON] = { size = 256, cells = 64, detail = 3 },
	},
}
local SLOT_COUNTS: { [Tier]: { [number]: number } } = {
	Low = {},
	Medium = { [Bodies.HOMEWORLD] = 2, [Bodies.MOON] = 2 },
	High = { [Bodies.HOMEWORLD] = 4, [Bodies.MOON] = 2 },
}
local CLOUD_TEXTURES: { [Tier]: TextureSpec } = {
	High = { size = 128, cells = 32, detail = 1 },
}
local CLOUD_SHELL_SCALE = 1.035 -- cloud shell radius / body radius (~2 km up on Earth)
local CLOUD_FADE_START = 1.15 -- x handover altitude: clouds invisible below ...
local CLOUD_FADE_END = 1.6 -- ... fully there above (the surface view below the handover has no cloud shell)
local SLOT_MAX_ALTITUDE_RADII = 4 -- detail slots only while the camera is lower than this many body radii
-- Atmosphere shells per tier, innermost first (at most ATMOSPHERE_MAX_LAYERS).
local ATMOSPHERE: { [Tier]: { AtmosphereLayer } } = {
	Low = {
		{ scale = 1.045, transparency = 0.78, color = Color3.fromRGB(120, 170, 255) }, -- the original shell
	},
	Medium = {
		{ scale = 1.014, transparency = 0.88, color = Color3.fromRGB(185, 215, 255) },
		{ scale = 1.045, transparency = 0.87, color = Color3.fromRGB(110, 160, 255) },
	},
	High = {
		{ scale = 1.006, transparency = 0.92, color = Color3.fromRGB(205, 228, 255) },
		{ scale = 1.015, transparency = 0.92, color = Color3.fromRGB(165, 205, 255) },
		{ scale = 1.028, transparency = 0.93, color = Color3.fromRGB(125, 175, 255) },
		{ scale = 1.045, transparency = 0.94, color = Color3.fromRGB(95, 145, 250) },
	},
}
local ATMOSPHERE_MAX_LAYERS = 4
local MAX_SHELL_SCALE = 1.045 -- the largest shell of any tier (ScaledSpace sizes proxies so it fits 2048 studs)
local PATCHES = 24
local FALLBACK_TIER: Tier = "Medium" -- settings for an unknown tier name
local BYTES_PER_PIXEL = 4
--============================================================================

local PlanetDetail = {}

function PlanetDetail.tierSpec(tier: Tier): TierSpec
	return TIERS[tier] or TIERS[FALLBACK_TIER]
end

-- CHANGED (Memory budget): per tier
function PlanetDetail.baseTexture(tier: Tier, bodyId: number): TextureSpec
	local specs = BASE_TEXTURES[tier] or BASE_TEXTURES[FALLBACK_TIER]
	return specs[bodyId] or DEFAULT_BASE_TEXTURE
end

function PlanetDetail.slotTexture(tier: Tier, bodyId: number): TextureSpec?
	if PlanetDetail.slotCount(tier, bodyId) <= 0 then
		return nil
	end
	local specs = SLOT_TEXTURES[tier]
	return if specs then specs[bodyId] else nil
end

-- CHANGED (Memory budget): detail slots on `bodyId` while it is the dominant body (0: none)
function PlanetDetail.slotCount(tier: Tier, bodyId: number): number
	local counts = SLOT_COUNTS[tier]
	return if counts then counts[bodyId] or 0 else 0
end

-- CHANGED (Memory budget): one image's EditableImage bytes
function PlanetDetail.imageBytes(spec: TextureSpec): number
	return spec.size * spec.size * BYTES_PER_PIXEL
end

function PlanetDetail.cloudTexture(tier: Tier): TextureSpec?
	if not PlanetDetail.tierSpec(tier).clouds then
		return nil
	end
	return CLOUD_TEXTURES[tier]
end

function PlanetDetail.atmosphereLayers(tier: Tier): { AtmosphereLayer }
	return ATMOSPHERE[tier] or ATMOSPHERE[FALLBACK_TIER]
end

-- Angular closeness of unit direction (ux, uy, uz) to patch `m` (row-major cube rotation): the cosine of the angle
-- to the patch's nearest point (1 inside the patch), from the patch-local gnomonic coordinates clamped to the
-- quarter face; -2 for patches on the far hemisphere.
function PlanetDetail.closeness(m: { number }, ux: number, uy: number, uz: number): number
	local lx = m[1] * ux + m[4] * uy + m[7] * uz
	local ly = m[2] * ux + m[5] * uy + m[8] * uz
	local lz = m[3] * ux + m[6] * uy + m[9] * uz
	if ly <= 1e-6 then
		return -2
	end
	local cx = math.clamp(lx / ly, -1, 0)
	local cz = math.clamp(lz / ly, -1, 0)
	local inv = 1 / math.sqrt(cx * cx + 1 + cz * cz)
	return (cx * lx + ly + cz * lz) * inv
end

--[[
	The `count` patches (indices into `rotations`) nearest unit direction u, nearest first. Ties are broken by the
	patch index, so the choice is deterministic.
]]
function PlanetDetail.desiredPatches(
	rotations: { { number } },
	ux: number,
	uy: number,
	uz: number,
	count: number
): { number }
	local scored: { { number } } = table.create(#rotations)
	for index, m in rotations do
		table.insert(scored, { PlanetDetail.closeness(m, ux, uy, uz), index })
	end
	table.sort(scored, function(a: { number }, b: { number }): boolean
		if a[1] ~= b[1] then
			return a[1] > b[1]
		end
		return a[2] < b[2]
	end)
	local result: { number } = table.create(math.max(count, 0))
	for k = 1, math.min(count, #scored) do
		table.insert(result, scored[k][2])
	end
	return result
end

-- Are detail slots worth painting at this altitude (m) over a body of this radius (m)?
function PlanetDetail.slotsWanted(altitude: number, radius: number): boolean
	return altitude < SLOT_MAX_ALTITUDE_RADII * radius
end

-- Cloud shell visibility 0..1: fades in above the proxy handover altitude (nothing below it draws clouds).
function PlanetDetail.cloudFade(altitude: number, handoverAltitude: number): number
	local a0, a1 = CLOUD_FADE_START * handoverAltitude, CLOUD_FADE_END * handoverAltitude
	local t = math.clamp((altitude - a0) / math.max(a1 - a0, 1e-6), 0, 1)
	return t * t * (3 - 2 * t)
end

-- EditableImage memory of a tier (bytes): every body's base textures, the largest body's slots, clouds.
-- CHANGED (Memory budget): slots per body (only the dominant body has them)
function PlanetDetail.textureBytes(tier: Tier): number
	local bytes = 0
	local slotBytes = 0
	for _, body in Bodies.List do
		if body.Kind ~= "Star" and not body.VisualOnly then
			bytes += PATCHES * PlanetDetail.imageBytes(PlanetDetail.baseTexture(tier, body.Id))
			local slot = PlanetDetail.slotTexture(tier, body.Id)
			if slot then
				slotBytes = math.max(slotBytes, PlanetDetail.slotCount(tier, body.Id) * PlanetDetail.imageBytes(slot))
			end
		end
	end
	bytes += slotBytes
	local cloud = PlanetDetail.cloudTexture(tier)
	if cloud then
		bytes += PATCHES * PlanetDetail.imageBytes(cloud)
	end
	return bytes
end

PlanetDetail.CLOUD_SHELL_SCALE = CLOUD_SHELL_SCALE
PlanetDetail.MAX_SHELL_SCALE = MAX_SHELL_SCALE
PlanetDetail.ATMOSPHERE_MAX_LAYERS = ATMOSPHERE_MAX_LAYERS

return table.freeze(PlanetDetail)
