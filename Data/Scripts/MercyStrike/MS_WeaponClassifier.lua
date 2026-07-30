-- Heavy-weapon classification from KCD2 1.5.6 item tables (Lua 5.1).
-- Runtime ItemManager data exposes the item UUID, but not XML Class.

MercyStrike = MercyStrike or {}
MercyStrike.WeaponClassifier = MercyStrike.WeaponClassifier or {}

local Classifier = MercyStrike.WeaponClassifier

-- Generated from MeleeWeapon records with Class 3 (axe) or Class 5 (mace)
-- across Libs/Tables/item/item*.xml. Keys are normalized item UUIDs.
local VANILLA_HEAVY = {
    ["007907cf-aeb9-4dfa-ad3f-e0262893e423"] = "mace",
    ["00b0039b-daa4-4f32-ac7f-69a6a2e0add8"] = "mace",
    ["01c3d4d6-b0a0-428f-b57b-8aee6fe3dfd8"] = "mace",
    ["0802c111-75aa-4b9c-9a3f-f30bac55fbc7"] = "axe",
    ["0f0164d5-3746-4d07-a1ed-0f138225a6d9"] = "axe",
    ["108b2f35-bfbb-4e20-bf5f-d0f4c59047ac"] = "mace",
    ["1291b8ef-0300-4c77-adb3-2a29a13902b6"] = "mace",
    ["12f52d70-ac6c-4637-be9e-d01a8c4ab961"] = "mace",
    ["1c3524bb-e4fa-48a1-b956-2dcbdbf69594"] = "axe",
    ["1dd5fd65-704f-4175-a57d-86e1f622a451"] = "mace",
    ["1fc42528-2bef-4dde-bf8a-04febeef41c8"] = "axe",
    ["214ffcdd-a7a7-4b7a-b484-f60c8d00b39b"] = "axe",
    ["2702fa59-4de3-42fb-b748-389374a7c7cb"] = "mace",
    ["28bef4ee-075b-4f13-9cb6-d84f59a09b64"] = "mace",
    ["29287483-8f15-4f6e-b48f-062a5f81877b"] = "mace",
    ["30dd9547-0ec9-4144-871c-cb66582244a4"] = "axe",
    ["31f86331-dfba-4b12-8641-f14af9307f09"] = "mace",
    ["3c3d9405-57cb-4aae-8832-05cd9891f38c"] = "mace",
    ["3c498ca0-455f-4ebe-884d-f4c2ea7de6ff"] = "axe",
    ["3d87d944-f57c-4c66-ad90-12145784ed3c"] = "mace",
    ["3f36611f-b026-4616-81a0-bd2a1c7dd313"] = "axe",
    ["402f6fc6-147e-487b-8024-19e8d3ffb5b6"] = "mace",
    ["4e91e216-73bb-47dc-bcd0-58b3ece477c9"] = "mace",
    ["50a9ac1e-dbb5-480b-8b5e-2ba3a1ff8d82"] = "axe",
    ["5337f947-aae1-469f-af2b-4b9716de2d20"] = "mace",
    ["53612e76-76fd-4dca-84b6-7905b986dc3b"] = "axe",
    ["53fd0cb7-015a-48ed-a42f-cd41f4b1b491"] = "mace",
    ["5d1a533b-c957-4875-9471-e76a48533968"] = "mace",
    ["5f7ecb68-3d15-4cbf-988a-9e8de87fa0d9"] = "mace",
    ["6158e0af-7b8d-448d-ac14-2e501e5470a2"] = "mace",
    ["636790d9-e443-4677-978e-e034386f6f86"] = "mace",
    ["63a1c8ca-1f25-44a3-9c10-a6c81856655a"] = "mace",
    ["65a211bd-2c7e-40a8-984f-66c8730444e4"] = "mace",
    ["662d7149-400f-4995-94b8-11c6fd208ca2"] = "axe",
    ["6c784241-c718-4caa-8054-97bbcd7a6a11"] = "mace",
    ["6eea57fb-b9db-4547-a833-db382b627e45"] = "mace",
    ["701b69bb-7c0f-4db8-aeff-1ce51044db14"] = "mace",
    ["71f8bad6-f5b8-403a-984b-ca85acd7fc81"] = "mace",
    ["73d76cba-003a-4d6f-afcd-cfdec4819a96"] = "mace",
    ["750a5405-4896-4459-8382-b27b27b53824"] = "mace",
    ["76a0c8f1-c55e-44b5-93ce-22a7145eac8d"] = "mace",
    ["7b1804a5-0a41-4acd-9260-037ae252c5d8"] = "mace",
    ["7c187d42-171d-4a95-80c5-03ea4c7e5849"] = "mace",
    ["808e13a4-810d-4ba6-8ce4-abf3dd62802e"] = "axe",
    ["81494400-b654-4aa7-8f31-c95c689db5f6"] = "axe",
    ["826b17e5-9fc9-4a25-81ab-98c740972e98"] = "mace",
    ["839992c8-657b-4d5e-97c9-96ff94430d72"] = "mace",
    ["8400f543-60dc-4e66-b618-fcb7783cfa72"] = "mace",
    ["8a9e3a36-213e-4b90-a4ec-518fdec1d980"] = "mace",
    ["8c9b97c5-832b-4f0f-a9cb-79cdaed38100"] = "mace",
    ["8cfad378-f16e-418f-b8a7-2a23ae724932"] = "mace",
    ["8d09fdad-9e86-4bbd-906e-ec01b668a206"] = "axe",
    ["8ebd6028-b2fc-4bde-9f16-265f5d446fcf"] = "mace",
    ["93a87db1-c332-409a-9044-6e54b516c0ee"] = "mace",
    ["9acebf6a-64a1-4d03-b090-f69332278cdc"] = "mace",
    ["9afb8d78-6f8d-4311-a9b9-11727f211ff3"] = "mace",
    ["9cc07405-4195-46ab-bf17-fd0fd99721bd"] = "mace",
    ["a2d34481-de50-41ed-8d9f-a52a5c9706af"] = "mace",
    ["a425fe0d-f3b4-437c-95d8-8dba0296f2d1"] = "mace",
    ["a92496ad-4a82-4815-93d8-5ae56bf78f88"] = "mace",
    ["a966bc20-b31f-4b7c-a4d6-2a5abe669f4f"] = "mace",
    ["aa424228-afb3-4084-8cac-dd3fdc03f2be"] = "mace",
    ["af6a6142-c6f7-4ae7-94a9-bb5be41ebecc"] = "mace",
    ["b28f5235-6e87-4e56-811c-69d4a9a605dd"] = "mace",
    ["b6ce8b62-9cab-428f-b1e8-0e12823f18c8"] = "axe",
    ["bd4caa9c-c51c-4aff-8cd9-d2ef5905b34c"] = "mace",
    ["bd74ce18-2623-48ba-a1a1-c9b09bbb2827"] = "axe",
    ["bef72593-22e6-44fc-a547-4d448000e6df"] = "mace",
    ["c1f6b8fe-2877-4ac6-bbbb-d35608162416"] = "mace",
    ["c25fc705-c957-4c9a-a831-0f112e3b148d"] = "axe",
    ["c4af6633-dacb-4d73-864a-30cabb1b6708"] = "axe",
    ["c64dcd8b-df93-4cb5-a80a-c71eb84ac6b0"] = "mace",
    ["c67de991-e22a-4a19-8b68-9369919c41dd"] = "mace",
    ["ce7a7cfe-3777-4804-861d-f5a09785ca4d"] = "mace",
    ["cff7ae16-d134-41bd-9394-89e8c3970f94"] = "mace",
    ["d3e20481-b4d5-499d-8b94-2a69b8d53973"] = "mace",
    ["d5ccfb38-b110-4bc6-8af9-1dde41fabe12"] = "mace",
    ["e041a0ef-789b-476f-9ae8-70a74a5ad5c8"] = "mace",
    ["e13a570f-03e1-4203-9338-d9823aa20b35"] = "mace",
    ["e2cf3e8b-b411-43a0-a7ed-2674ae8ac4d2"] = "axe",
    ["e38cfdef-5184-444a-9689-c35969ea5e5c"] = "mace",
    ["e86cf667-1449-4111-9bb5-17329a526278"] = "axe",
    ["edaa337a-5ed7-4d49-8b89-5d9693dabf1d"] = "axe",
    ["eeeb5a48-9a97-41a6-aee0-3e1b64fc2405"] = "axe",
    ["f2e86f22-8932-4751-8f62-fb1b8b846ddf"] = "mace",
    ["f65df177-966b-48e5-8cc6-26a4f95e41b0"] = "mace",
    ["f8f7f4bb-7474-43d3-9c44-36793f83e7a4"] = "mace",
    ["fdfd6989-a28d-40bc-ac0d-882b4d1cf4f9"] = "axe",
    ["fe6b84cb-29ca-4897-a380-ef5ab5573007"] = "mace",
    ["ff1a4d2f-efda-4ebc-a0d0-dc3e3e6fb132"] = "mace",
}

local registeredHeavy = {}

local function normalizeId(itemId)
    if itemId == nil then return nil end
    local normalized = string.lower(tostring(itemId))
    if normalized == "" or normalized == "nil" then return nil end
    return normalized
end

function Classifier.Classify(itemId)
    local normalized = normalizeId(itemId)
    if not normalized then
        return false, nil, "noItem"
    end
    local registered = registeredHeavy[normalized]
    if registered then
        return true, registered, "registeredOverride"
    end
    local vanilla = VANILLA_HEAVY[normalized]
    if vanilla then
        return true, vanilla, "vanillaXml"
    end
    return false, nil, "notInHeavyIndex"
end

-- Compatibility hook for add-ons whose new item UUIDs cannot be discovered
-- from the sparse runtime item table.
function Classifier.RegisterHeavyWeapon(itemId, family)
    local normalized = normalizeId(itemId)
    local normalizedFamily = string.lower(tostring(family or "heavy"))
    if not normalized then return false end
    if normalizedFamily ~= "axe" and normalizedFamily ~= "mace" then
        normalizedFamily = "heavy"
    end
    registeredHeavy[normalized] = normalizedFamily
    return true
end

function Classifier.GetIndexedCount()
    local count = 0
    for _ in pairs(VANILLA_HEAVY) do count = count + 1 end
    return count
end
