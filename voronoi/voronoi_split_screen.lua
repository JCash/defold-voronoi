-- Reusable Voronoi split-screen controller.
--
-- Owns grouping, merge/split transitions, Voronoi generation, stencil mask
-- buffers, divider geometry, and camera placement. The caller owns the world,
-- actors, input, and any example-specific presentation.

local M = {}

local function copy_vectors(values)
    local result = {}
    for i, value in ipairs(values) do
        result[i] = vmath.vector3(value.x, value.y, value.z)
    end
    return result
end

local function copy_values(values)
    local result = {}
    for i, value in ipairs(values or {}) do
        result[i] = value
    end
    return result
end

local function flattened_sites(sites)
    local values = {}
    for _, site in ipairs(sites) do
        values[#values + 1] = site.x
        values[#values + 1] = site.y
    end
    return values
end

local function group_signature(group_ids)
    return table.concat(group_ids, ":")
end

local function smoothstep(value)
    return value * value * (3 - 2 * value)
end

local function build_camera_groups(state, sites, previous_group_ids)
    local parents = {}
    for i = 1, #sites do
        parents[i] = i
    end

    local function root(index)
        while parents[index] ~= index do
            parents[index] = parents[parents[index]]
            index = parents[index]
        end
        return index
    end

    local function join(a, b)
        local root_a = root(a)
        local root_b = root(b)
        if root_a ~= root_b then
            parents[root_b] = root_a
        end
    end

    for a = 1, #sites do
        for b = a + 1, #sites do
            local dx = sites[a].x - sites[b].x
            local dy = sites[a].y - sites[b].y
            local previously_grouped = previous_group_ids and previous_group_ids[a] == previous_group_ids[b]
            local threshold = previously_grouped and state.split_distance or state.merge_distance
            if dx * dx + dy * dy <= threshold * threshold then
                join(a, b)
            end
        end
    end

    local groups = {}
    local groups_by_root = {}
    for site_index, site in ipairs(sites) do
        local group_root = root(site_index)
        local group = groups_by_root[group_root]
        if not group then
            group = { members = {}, site = vmath.vector3() }
            groups_by_root[group_root] = group
            groups[#groups + 1] = group
        end
        group.members[#group.members + 1] = site_index
        group.site.x = group.site.x + site.x
        group.site.y = group.site.y + site.y
    end

    local group_ids = {}
    for _, group in ipairs(groups) do
        group.site.x = group.site.x / #group.members
        group.site.y = group.site.y / #group.members
        for _, site_index in ipairs(group.members) do
            group_ids[site_index] = group.members[1]
        end
    end
    return groups, group_ids
end

local function build_transition_targets(state, sites)
    local site_targets = {}
    local camera_targets = {}
    for _, group in ipairs(state.camera_groups) do
        for member_index, site_index in ipairs(group.members) do
            local target = sites[site_index]
            if #group.members > 1 then
                -- Sub-pixel ring offsets keep sites distinct without moving
                -- their average away from the shared group centroid.
                local angle = math.pi * 2 * (member_index - 1) / #group.members
                target = vmath.vector3(
                    group.site.x + math.cos(angle) * state.merged_site_radius,
                    group.site.y + math.sin(angle) * state.merged_site_radius,
                    0)
            end
            site_targets[site_index] = target
            camera_targets[site_index] = group.site
        end
    end
    return site_targets, camera_targets
end

local function make_mask_buffer(state, region)
    local result = buffer.create(#region.edges * 3, {
        { name = hash("position"), type = buffer.VALUE_TYPE_FLOAT32, count = 3 },
    })
    local positions = buffer.get_stream(result, hash("position"))
    local cursor = 1
    for _, edge in ipairs(region.edges) do
        local points = {
            region.x, region.y, 0,
            edge[1].x, edge[1].y, 0,
            edge[2].x, edge[2].y, 0,
        }
        for _, value in ipairs(points) do
            positions[cursor] = value
            cursor = cursor + 1
        end
    end
    buffer.set_metadata(result, hash("AABB"), {
        0, 0, -1, state.width, state.height, 1,
    }, buffer.VALUE_TYPE_FLOAT32)
    return result
end

local function push_colored_vertex(vertices, colors, point, color)
    vertices[#vertices + 1] = point.x
    vertices[#vertices + 1] = point.y
    vertices[#vertices + 1] = point.z or 0
    colors[#colors + 1] = color.x
    colors[#colors + 1] = color.y
    colors[#colors + 1] = color.z
    colors[#colors + 1] = color.w
end

local function add_colored_triangle(vertices, colors, a, b, c, color)
    push_colored_vertex(vertices, colors, a, color)
    push_colored_vertex(vertices, colors, b, color)
    push_colored_vertex(vertices, colors, c, color)
end

local function make_divider_buffer(state)
    local vertices = {}
    local colors = {}
    local edge_records = {}
    local divider_edge_count = 0

    for _, region in ipairs(voronoi.get_regions(state.diagram)) do
        for _, edge in ipairs(region.edges) do
            local first = string.format("%.3f,%.3f", edge[1].x, edge[1].y)
            local second = string.format("%.3f,%.3f", edge[2].x, edge[2].y)
            local edge_key = first < second and first .. ":" .. second or second .. ":" .. first
            local record = edge_records[edge_key]
            if not record then
                record = { edge = edge, regions = {} }
                edge_records[edge_key] = record
            end
            record.regions[#record.regions + 1] = region.index
        end
    end

    -- An interior edge occurs in two region polygons. Deriving adjacency from
    -- shared geometry also guarantees the visible divider matches the masks.
    for _, record in pairs(edge_records) do
        if #record.regions == 2 then
            divider_edge_count = divider_edge_count + 1
            local region_index = record.regions[1]
            local neighbor = record.regions[2]
            local was_separate = state.transition_from_group_ids[region_index] ~= state.transition_from_group_ids[neighbor]
            local is_separate = state.player_group_ids[region_index] ~= state.player_group_ids[neighbor]
            local from = was_separate and 1 or 0
            local target = is_separate and 1 or 0
            local visibility = from + (target - from) * state.transition_ease
            local edge = record.edge
            local dx = edge[2].x - edge[1].x
            local dy = edge[2].y - edge[1].y
            local length = math.sqrt(dx * dx + dy * dy)
            if visibility > 0.01 and length > 0.001 then
                local half_width = state.divider_width * 0.5
                local nx = -dy / length * half_width
                local ny = dx / length * half_width
                local a = vmath.vector3(edge[1].x + nx, edge[1].y + ny, state.divider_z)
                local b = vmath.vector3(edge[2].x + nx, edge[2].y + ny, state.divider_z)
                local c = vmath.vector3(edge[2].x - nx, edge[2].y - ny, state.divider_z)
                local d = vmath.vector3(edge[1].x - nx, edge[1].y - ny, state.divider_z)
                local color = state.divider_colors[region_index] or vmath.vector4(1, 1, 1, 1)
                local faded = vmath.vector4(color.x, color.y, color.z, color.w * visibility)
                add_colored_triangle(vertices, colors, a, b, c, faded)
                add_colored_triangle(vertices, colors, a, c, d, faded)
            end
        end
    end

    if #vertices == 0 then
        add_colored_triangle(vertices, colors, vmath.vector3(), vmath.vector3(), vmath.vector3(), vmath.vector4())
    end
    local result = buffer.create(#vertices / 3, {
        { name = hash("position"), type = buffer.VALUE_TYPE_FLOAT32, count = 3 },
        { name = hash("color"), type = buffer.VALUE_TYPE_FLOAT32, count = 4 },
    })
    local position_stream = buffer.get_stream(result, hash("position"))
    local color_stream = buffer.get_stream(result, hash("color"))
    for i = 1, #vertices do
        position_stream[i] = vertices[i]
    end
    for i = 1, #colors do
        color_stream[i] = colors[i]
    end
    buffer.set_metadata(result, hash("AABB"), {
        0, 0, -1, state.width, state.height, 1,
    }, buffer.VALUE_TYPE_FLOAT32)
    return result, divider_edge_count
end

local function default_camera_position(state, site)
    return vmath.vector3(
        site.x - (site.x - state.width * 0.5) / state.camera_zoom,
        site.y - (site.y - state.height * 0.5) / state.camera_zoom,
        state.camera_z)
end

local function update_cameras(state)
    for i, target_site in ipairs(state.camera_target_sites) do
        local target = state.camera_position(state, target_site, i)
        local origin = state.transition_from_cameras and state.transition_from_cameras[i] or target
        go.set_position(vmath.lerp(state.transition_ease, origin, target), state.camera_paths[i])
    end

    local message = { count = #state.camera_urls }
    for i, camera_url in ipairs(state.camera_urls) do
        message["camera_" .. i] = camera_url
    end
    msg.post(state.render_url, state.set_cameras_message, message)
end

function M.create(options)
    assert(options, "split-screen options are required")
    assert(options.width and options.height, "split-screen width and height are required")
    assert(options.camera_paths and options.camera_urls, "split-screen cameras are required")
    assert(options.mask_resources, "split-screen mask resources are required")
    assert(options.divider_resource, "split-screen divider resource is required")
    assert(#options.camera_paths == #options.camera_urls, "camera path/url counts must match")
    assert(#options.camera_paths == #options.mask_resources, "camera/mask counts must match")

    local state = {
        width = options.width,
        height = options.height,
        merge_distance = options.merge_distance or 150,
        split_distance = options.split_distance or 190,
        transition_duration = options.transition_duration or 0.55,
        merged_site_radius = options.merged_site_radius or 0.35,
        divider_width = options.divider_width or 2,
        divider_z = options.divider_z or 0.8,
        divider_colors = options.divider_colors or {},
        camera_zoom = options.camera_zoom or 1,
        camera_z = options.camera_z or 10,
        camera_position = options.camera_position or default_camera_position,
        camera_paths = options.camera_paths,
        camera_urls = options.camera_urls,
        mask_resources = options.mask_resources,
        divider_resource = options.divider_resource,
        render_url = options.render_url or "@render:",
        set_cameras_message = options.set_cameras_message or "set_voronoi_cameras",
        clear_cameras_message = options.clear_cameras_message or "clear_voronoi_cameras",
        diagram = voronoi.create(options.width, options.height),
    }
    return state
end

function M.update(state, sites, dt, snap)
    assert(#sites == #state.camera_paths, "one site is required for each camera")
    local previous_group_ids = state.player_group_ids
    local groups, next_group_ids = build_camera_groups(state, sites, previous_group_ids)
    local next_signature = group_signature(next_group_ids)

    state.camera_groups = groups
    state.player_group_ids = next_group_ids
    state.site_targets, state.camera_target_sites = build_transition_targets(state, sites)

    if state.group_signature ~= next_signature then
        state.transition_from_sites = copy_vectors(state.diagram_sites or sites)
        state.transition_from_cameras = {}
        for i, path in ipairs(state.camera_paths) do
            state.transition_from_cameras[i] = go.get_position(path)
        end
        state.transition_from_group_ids = copy_values(previous_group_ids or next_group_ids)
        state.group_signature = next_signature
        state.transition_elapsed = 0
    end

    if snap then
        state.transition_elapsed = state.transition_duration
    else
        state.transition_elapsed = math.min(
            state.transition_duration,
            (state.transition_elapsed or state.transition_duration) + dt)
    end
    local progress = state.transition_elapsed / state.transition_duration
    state.transition_ease = smoothstep(progress)

    state.diagram_sites = state.diagram_sites or {}
    for i, target in ipairs(state.site_targets) do
        local origin = state.transition_from_sites and state.transition_from_sites[i] or target
        state.diagram_sites[i] = vmath.lerp(state.transition_ease, origin, target)
    end

    voronoi.generate(state.diagram, flattened_sites(state.diagram_sites))
    for _, region in ipairs(voronoi.get_regions(state.diagram)) do
        resource.set_buffer(state.mask_resources[region.index], make_mask_buffer(state, region))
    end
    local divider_buffer, divider_edge_count = make_divider_buffer(state)
    resource.set_buffer(state.divider_resource, divider_buffer)
    state.divider_edge_count = divider_edge_count
    state.region_count = voronoi.get_num_regions(state.diagram)
    update_cameras(state)
    return state
end

function M.destroy(state)
    msg.post(state.render_url, state.clear_cameras_message)
    if state.diagram then
        voronoi.destroy(state.diagram)
        state.diagram = nil
    end
end

function M.get_group_count(state)
    return #state.camera_groups
end

function M.get_transition(state)
    return state.transition_ease
end

function M.get_region_count(state)
    return state.region_count
end

function M.get_divider_edge_count(state)
    return state.divider_edge_count
end

function M.get_diagram(state)
    return state.diagram
end

return M
