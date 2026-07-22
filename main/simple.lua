-- This system doesn't really do much
-- It just lets the particles bounce around

local M = {}

local num_particles = 0
local particles = {}
local velocities = {}
local width = 0
local height = 0

local pixels_per_meter = 8

local function add_particle()
    local x = math.random() * width
    local y = math.random() * height
    particles[#particles + 1] = vmath.vector3(x, y, 0.1)

    local vx = (math.random() * 2 - 1) * width * 0.05
    local vy = (math.random() * 2 - 1) * width * 0.05
    velocities[#velocities + 1] = vmath.vector3(vx, vy, 0)
end

function M.init_particles(_diagram, num, _width, _height)
    num_particles = num
    particles = {}
    velocities = {}
    width = _width
    height = _height

    for i=1,num_particles do
        add_particle()
    end
end

function M.set_particle_count(count)
    count = math.max(1, math.floor(count))
    while num_particles < count do
        add_particle()
        num_particles = num_particles + 1
    end
    while num_particles > count do
        particles[num_particles] = nil
        velocities[num_particles] = nil
        num_particles = num_particles - 1
    end
end

function M.set_particle_position(index, x, y)
    if not particles[index] then
        return false
    end
    particles[index] = vmath.vector3(
        math.max(0, math.min(width, x)),
        math.max(0, math.min(height, y)),
        0.1)
    return true
end

function M.offset_particle(index, dx, dy)
    local particle = particles[index]
    if not particle then
        return false
    end
    particle.x = math.max(0, math.min(width, particle.x + dx))
    particle.y = math.max(0, math.min(height, particle.y + dy))
    return true
end

function M.update_particles(dt)
    for i=1,num_particles do
        local p = particles[i]
        local v = velocities[i]
        
        --local v1 = v + vmath.vector3(0, -9.82 * pixels_per_meter, 0) * dt
        local v1 = v
        local t = (v + v1) * dt * 0.5
        p = p + t
        v = v1
        
        if p.x < 0 then
            p.x = -p.x
            v.x = -v.x
        elseif p.x > width then
            p.x = width - (p.x - width)
            v.x = -v.x
        end
        
        if p.y < 0 then
            p.y = -p.y
            v.y = -v.y * 0.95
        elseif p.y > height then
            p.y = height - (p.y - height)
            v.y = -v.y
        end
        
        particles[i] = p
        velocities[i] = v
    end
end

function M.get_particles()
    return particles
end

return M
