require "prefabutil"

local easing = require("easing")

local assets =
{
    Asset("ANIM", "anim/boat_cannon.zip"),
}

local prefabs =
{
    "cannonball_rock",
    "collapse_small",
    "cannon_aoe_range_fx",
    "cannon_reticule_fx",
}

local function onhammered(inst, worker)
    if inst.components.burnable ~= nil and inst.components.burnable:IsBurning() then
        inst.components.burnable:Extinguish()
    end

    inst.components.lootdropper:DropLoot()
    local fx = SpawnPrefab("collapse_small")
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    fx:SetMaterial("metal")

    -- Is the cannon loaded with ammo? Spawn it.
    local boatcannon = inst.components.boatcannon
    if boatcannon and boatcannon:IsAmmoLoaded() then
        local ammo = SpawnPrefab(boatcannon.loadedammo .. "_item")
        if ammo then
            local pt = inst:GetPosition()
            ammo.Transform:SetPosition(pt:Get())
            inst.components.lootdropper:FlingItem(ammo, pt)
        end
    end

    inst:Remove()
end

local function onhit(inst, worker)
    if not (inst:HasTag("burnt") or inst.sg:HasStateTag("busy")) then
        inst.sg:GoToState("hit", inst.sg:HasStateTag("light"))
    end
end

local function getstatus(inst, viewer)
    local boatcannon = inst.components.boatcannon
    if boatcannon and boatcannon:IsAmmoLoaded() then
        return "AMMOLOADED"
    else
        return "GENERIC"
    end
end

local function onsave(inst, data)
    if inst:HasTag("burnt") or (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) then
        data.burnt = true
    end
end

local MONKEY_ISLAND_CENTER_TAGS = { "monkeyqueen" }
local function try_autoorient(inst)
    local autoorientprefab = FindEntity(inst, 100, nil, MONKEY_ISLAND_CENTER_TAGS)
    if autoorientprefab ~= nil then
        local aox, aoy, aoz = autoorientprefab.Transform:GetWorldPosition()
        local angle_awayfrom_aop = inst:GetAngleToPoint(aox, 0, aoz) + 180
        inst.Transform:SetRotation(angle_awayfrom_aop)
    end
end

local function onload(inst, data)
    if data == nil then
        return
    end

    if data.burnt and inst.components.burnable ~= nil and inst.components.burnable.onburnt ~= nil then
        inst.components.burnable.onburnt(inst)
    end

    if inst.components.boatcannon then
        -- Show/hide anim flap depending on if ammo is loaded or not
		if inst.components.boatcannon:IsAmmoLoaded() then
            inst.AnimState:HideSymbol("cannon_flap_up")
			inst.AnimState:ShowSymbol("cannon_flap_down")
        else
			inst.AnimState:ShowSymbol("cannon_flap_up")
            inst.AnimState:HideSymbol("cannon_flap_down")
        end
    end

    if data.autogenerated then
        -- Wait a frame to make sure that the thing we're looking for is around.
        inst:DoTaskInTime(0, try_autoorient)
    end
end

local function onloadpostpass(inst, newents, data)
    if inst.components.savedrotation then
        local savedrotation = data ~= nil and data.savedrotation ~= nil and data.savedrotation.rotation or 0
        inst.components.savedrotation:ApplyPostPassRotation(savedrotation)
    end
end

local function onbuilt(inst, data)
    inst.sg:GoToState("place")

    local pt = data.pos
    if pt == nil then
        return
    end

    -- Orient the cannon's angle so it points outwards from the center.
    local boat = TheWorld.Map:GetPlatformAtPoint(pt.x, pt.z)
    if boat ~= nil then
        local angle = GetAngleFromBoat(boat, pt.x, pt.z) / DEGREES
        inst.Transform:SetRotation(-angle)
    -- Placing it on the ground; use the placer's rotation, which should use the camera's rotation angle
    else
        inst.Transform:SetRotation(data.rot or 0)
    end
end

local function abletoaccepttest(inst, item)
    return item:HasTag("boatcannon_ammo") and inst.components.boatcannon and inst.components.boatcannon:IsAmmoLoaded()
end

local function ongivenitem(inst, giver, item)
    if inst.components.boatcannon == nil then
        return
    end

	if item ~= nil and item.projectileprefab ~= nil and item:HasTag("boatcannon_ammo") then
		inst.components.boatcannon:LoadAmmo(item.projectileprefab)
	end
end

local function CancelOperator(inst)
    local operator = inst.components.boatcannon.operator
    if operator ~= nil and operator.components.boatcannonuser ~= nil then
        operator.components.boatcannonuser:SetCannon(nil)
    end
end

local function onburnt(inst)
    CancelOperator(inst)
	DefaultBurntStructureFn(inst)
end

--------------------------------------------------------------------------
-- The distance that a cannonball travels when it hits the ground
local function CalculateShotRange()
	local vel = TUNING.CANNONBALLS.ROCK.SPEED
	local angle = 30 * DEGREES -- Same as complexprojectile not enough speed to reach endPos angle (fix this later?)
	local g = -TUNING.CANNONBALLS.ROCK.GRAVITY
	local height = TUNING.BOAT.BOATCANNON.PROJECTILE_INITIAL_HEIGHT

	return vel * math.cos(angle) * (vel * math.sin(angle) + math.sqrt(math.pow(vel * math.sin(angle), 2) + 2 * g * height)) / g
end

local RANGE = CalculateShotRange()

local function ClampReticulePos(inst, pos, newx, newz)
    -- Check if direction held is within the cannon's firing arc
    --local px, py, pz = ThePlayer.Transform:GetWorldPosition()
    --local base_aim_angle = 180 - GetAngleFromBoat(inst, px, pz) / DEGREES
    --V2C: just use our rotation for now because the vector to player is not smooth over the network on a rotating platform
    local base_aim_angle = inst.Transform:GetRotation()
    local base_aim_facing = Vector3(math.cos(-base_aim_angle / RADIANS), 0 , math.sin(-base_aim_angle / RADIANS))
    local withinangle = IsWithinAngle(inst:GetPosition(), base_aim_facing, TUNING.BOAT.BOATCANNON.AIM_ANGLE_WIDTH, pos - Vector3(newx, 0, newz))
    if not withinangle then
        --[[if IsWithinAngle(inst:GetPosition(), base_aim_facing, TUNING.BOAT.BOATCANNON.AIM_ANGLE_WIDTH, pos - Vector3(-newx, 0, -newz)) then
            newx = -newx
            newz = -newz
        else]]
            -- Return the closest min/max allowable angle to the controller's facing angle
            local minangle = base_aim_angle - TUNING.BOAT.BOATCANNON.AIM_ANGLE_WIDTH / 2 * RADIANS
            local minanglepos = Vector3(pos.x + math.cos(-minangle / RADIANS) * RANGE, 0 , pos.z + math.sin(-minangle / RADIANS) * RANGE)
            local maxangle = base_aim_angle + TUNING.BOAT.BOATCANNON.AIM_ANGLE_WIDTH / 2 * RADIANS
            local maxanglepos = Vector3(pos.x + math.cos(-maxangle / RADIANS) * RANGE, 0 , pos.z + math.sin(-maxangle / RADIANS) * RANGE)

            local facingpos = Vector3(pos.x + newx * RANGE, 0, pos.z + newz * RANGE)
            local dist_to_min = VecUtil_Dist(facingpos.x, facingpos.z, minanglepos.x, minanglepos.z)
            local dist_to_max = VecUtil_Dist(facingpos.x, facingpos.z, maxanglepos.x, maxanglepos.z)

            facingpos = dist_to_min < dist_to_max and maxanglepos or minanglepos
            return facingpos
        --end
    end

    pos.x = pos.x - (newx * RANGE)
    pos.z = pos.z - (newz * RANGE)
    return pos
end

local function reticule_mouse_target_function(inst, mousepos)
    if mousepos == nil then
        return nil
    end

    local pos = Vector3(inst.Transform:GetWorldPosition())
    local dir = pos - mousepos
    if dir.x ~= 0 or dir.z ~= 0 then
        dir = dir:GetNormalized()
        return ClampReticulePos(inst, pos, dir.x, dir.z)
    end

    return Vector3(inst.entity:LocalToWorldSpace(RANGE, 0, 0))
end

local function reticule_target_function(inst)
    if ThePlayer and ThePlayer.components.playercontroller ~= nil and ThePlayer.components.playercontroller.isclientcontrollerattached then
        local pos = Vector3(inst.Transform:GetWorldPosition())

        local dir = Vector3()
		dir.y = 0
		if TheInput:SupportsControllerFreeAiming() then
			dir.x = TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_AIM_RIGHT) - TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_AIM_LEFT)
			dir.z = TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_AIM_UP) - TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_AIM_DOWN)
		else
			dir.x = TheInput:GetAnalogControlValue(CONTROL_MOVE_RIGHT) - TheInput:GetAnalogControlValue(CONTROL_MOVE_LEFT)
			dir.z = TheInput:GetAnalogControlValue(CONTROL_MOVE_UP) - TheInput:GetAnalogControlValue(CONTROL_MOVE_DOWN)
		end
		local deadzone = TUNING.CONTROLLER_DEADZONE_RADIUS

        local reticule = inst.components.reticule.reticule
        if math.abs(dir.x) >= deadzone or math.abs(dir.z) >= deadzone then
            dir = dir:GetNormalized()
            if reticule ~= nil then
                reticule._lastdir = dir
            end
        else
            dir = reticule ~= nil and reticule._lastdir or nil
        end

        if dir ~= nil then
            local Camangle = TheCamera:GetHeading()/180
            local theta = -PI *(0.5 - Camangle)

            local newx = dir.x * math.cos(theta) - dir.z *math.sin(theta)
            local newz = dir.x * math.sin(theta) + dir.z *math.cos(theta)

            return ClampReticulePos(inst, pos, newx, newz)
        end
    end

    return Vector3(inst.entity:LocalToWorldSpace(RANGE, 0, 0))
end

local function reticule_update_position_function(inst, pos, reticule, ease, smoothing, dt)
    reticule.Transform:SetPosition(pos:Get())
    reticule.Transform:SetRotation(inst:GetAngleToPoint(pos))
end

local function onlit(inst)
    if inst.components.boatcannon:IsAmmoLoaded() then
        inst.sg:GoToState("shoot")
        CancelOperator(inst)
    end
end

local function OnAmmoLoaded(inst)
	if not POPULATING then
		inst.sg:GoToState("load")
	end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddLight()
    inst.entity:AddNetwork()

	inst:SetDeploySmartRadius(DEPLOYSPACING_RADIUS[DEPLOYSPACING.LESS] / 2) --match kit item
    MakeObstaclePhysics(inst, 0.25)

    inst.AnimState:SetBank("boat_cannon")
    inst.AnimState:SetBuild("boat_cannon")
    inst.AnimState:PlayAnimation("idle")
	inst.AnimState:HideSymbol("cannon_flap_down")

    inst.scrapbook_specialinfo = "BOATCANNON"

    inst:AddTag("boatcannon")
    inst.Transform:SetEightFaced()

    inst:AddComponent("reticule")
    inst.components.reticule.reticuleprefab = "cannon_reticule_fx"
    inst.components.reticule.mouseenabled = true
    inst.components.reticule.mousetargetfn = reticule_mouse_target_function
    inst.components.reticule.targetfn = reticule_target_function
    inst.components.reticule.updatepositionfn = reticule_update_position_function
    --inst.components.reticule.ease = true
    inst.components.reticule.ispassableatallpoints = true

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:ListenForEvent("onbuilt", onbuilt)

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = getstatus

    MakeSmallBurnable(inst, TUNING.MED_BURNTIME)
    MakeSmallPropagator(inst)
    inst.components.burnable:SetOnBurntFn(onburnt)

    inst:AddComponent("lootdropper")
    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(4)
    inst.components.workable:SetOnFinishCallback(onhammered)
    inst.components.workable:SetOnWorkCallback(onhit)

    inst:AddComponent("savedrotation")

    if inst.components.trader == nil then
        inst:AddComponent("trader")
        inst.components.trader:SetAbleToAcceptTest(abletoaccepttest)
        inst.components.trader.onaccept = ongivenitem
    end

    inst:AddComponent("timer")

    inst.OnSave = onsave
    inst.OnLoad = onload
    inst.OnLoadPostPass = onloadpostpass

    inst:AddComponent("boatcannon")

    MakeHauntableWork(inst)

    inst:SetStateGraph("SGboatcannon")

    inst:ListenForEvent("onignite", onlit)
    inst:ListenForEvent("ammoloaded", OnAmmoLoaded)

    return inst
end

local function setup_boat_cannon_placer(inst)
    inst.components.placer.rotate_from_boat_center = true
    inst.components.placer.rotationoffset = 180
end

return Prefab("boat_cannon", fn, assets, prefabs),
    MakeDeployableKitItem("boat_cannon_kit", "boat_cannon", "boat_cannon", "boat_cannon", "kit", assets, nil, {"boat_accessory"}, {fuelvalue = TUNING.LARGE_FUEL}, { deployspacing = DEPLOYSPACING.LESS }),
    MakePlacer("boat_cannon_kit_placer", "boat_cannon", "boat_cannon", "idle", false, false, false, nil, 0, "eight", setup_boat_cannon_placer)
