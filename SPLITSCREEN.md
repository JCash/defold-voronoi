# Integrating Voronoi split screen

This guide explains how to add the reusable Voronoi split-screen controller to
an existing Defold project and render script. The complete working reference is
the [multicamera example](examples/multicamera/multicamera.collection), its
[render script](render/voronoi.render_script), and the reusable
[controller module](voronoi/voronoi_split_screen.lua).

The controller handles proximity grouping, merge/split hysteresis, animated
site convergence, camera interpolation, Voronoi generation, stencil-mask
buffers, and divider geometry. Your game continues to own player movement,
world rendering, camera components, and presentation.

## Multicamera example

`/examples/multicamera/multicamera.collection` contains one human-controlled
player and two NPCs moving on intersecting circular paths. Their world positions
form the Voronoi sites. Players merge into one group below 150 pixels and split
again above 190 pixels. The hysteresis prevents threshold chatter.

A 0.55-second smoothstep transition converges each group's sites and cameras on
its centroid. All three passes remain alive with tiny site offsets, so no
topology swap occurs at the end of the animation. Internal dividers fade as the
views become identical, making each group appear as one shared camera region.

Each cell is converted into a dynamic triangle-fan mesh, written into the
stencil buffer, then the shared world—including every player—is rendered through
that group camera inside the stencil. Players are also rendered in a final
unclipped owner-camera pass, so an actor crossing a split remains intact while
the per-camera world views stay stencil-clipped. The visible dividers are a
dynamic mesh built from the same cell edges as the stencil masks.

Move P1 with WASD, the arrow keys, or by dragging the cyan player. The camera
passes use `/render/voronoi.render_script`; the mask meshes and world mesh are in
`/examples/multicamera/`.

## Rendering model

Every view has four pieces of state:

1. A world-space site, normally the owning player's position.
2. A camera component and its game object path.
3. A screen-space triangle mesh covering that site's Voronoi cell.
4. A unique render predicate for the mask mesh.

For every camera, the render script clears only the stencil buffer, writes that
camera's cell as stencil value `1`, and renders the world where the stencil is
equal to `1`. The color buffer is retained between camera passes, so the cells
compose into one frame. The divider mesh and GUI are rendered afterward in
screen space.

The bundled implementation keeps all sites and camera passes alive while views
merge. Sites converge to distinct sub-pixel offsets and grouped cameras converge
to the same transform. This makes the frames on both sides of a merge visually
identical and avoids a topology-change snap.

## 1. Prepare material tags and mesh resources

The reference render script uses these tags:

| Purpose | Material tag |
| --- | --- |
| Split-screen world | `voronoi_world` |
| View 1 mask | `voronoi_mask_1` |
| View 2 mask | `voronoi_mask_2` |
| View 3 mask | `voronoi_mask_3` |
| Optional owner actor 1 | `voronoi_actor_1` |
| Optional owner actor 2 | `voronoi_actor_2` |
| Optional owner actor 3 | `voronoi_actor_3` |
| Divider overlay | `voronoi_divider` |

Tag the materials used by the world you want to render through every camera
with `voronoi_world`. You can use multiple materials as long as they all carry
that tag.

Create one dynamic mask mesh per camera. Each mask must have:

- its own `.buffer` resource containing a `position` float32 stream with three
  components;
- its own material tag, such as `voronoi_mask_1`;
- `PRIMITIVE_TRIANGLES`; and
- a vertex shader using the standard worldview and projection constants.

Do not share one mutable buffer between mask meshes. The controller updates each
cell independently, so shared buffers cause the last cell to overwrite all the
others. The example resources are
[`mask_1.mesh`](examples/multicamera/mask_1.mesh),
[`mask_1.material`](examples/multicamera/mask_1.material), and
[`mask_1.buffer`](examples/multicamera/mask_1.buffer); duplicate that pattern for
each view.

Create one divider mesh with position and color streams, the
`voronoi_divider` tag, and alpha blending. The controller generates this mesh
from the exact shared edges used by the masks, preventing visible lines from
drifting away from stencil boundaries. See
[`divider.mesh`](examples/multicamera/divider.mesh).

## 2. Add predicates to the render script

Keep your existing predicates and add the split-screen predicates in
`init(self)`:

```lua
self.world_pred = render.predicate({ "voronoi_world" })
self.divider_pred = render.predicate({ "voronoi_divider" })
self.mask_preds = {
    render.predicate({ "voronoi_mask_1" }),
    render.predicate({ "voronoi_mask_2" }),
    render.predicate({ "voronoi_mask_3" }),
}
```

The example also gives every player a unique actor predicate:

```lua
self.actor_preds = {
    render.predicate({ "voronoi_actor_1" }),
    render.predicate({ "voronoi_actor_2" }),
    render.predicate({ "voronoi_actor_3" }),
}
```

These actor predicates are optional. They allow the render script to draw all
actors inside every camera cell and then draw each actor once more, without a
stencil, through its owning camera. That final owner pass prevents a player from
being cut in half when crossing a split line.

## 3. Receive camera lifecycle messages

The controller posts `set_voronoi_cameras` after each update and
`clear_voronoi_cameras` when destroyed. Add message hashes and store the active
cameras in your render script:

```lua
local MSG_SET_CAMERAS = hash("set_voronoi_cameras")
local MSG_CLEAR_CAMERAS = hash("clear_voronoi_cameras")

function on_message(self, message_id, message)
    if message_id == MSG_SET_CAMERAS then
        self.cameras = {
            message.camera_1,
            message.camera_2,
            message.camera_3,
        }
        self.camera_count = message.count or 3
    elseif message_id == MSG_CLEAR_CAMERAS then
        self.cameras = nil
        self.camera_count = nil
    end
end
```

Keep your existing render messages in the same handler. When `self.cameras` is
`nil`, use your original single-camera/default rendering path. This lets menus
and non-split-screen collections continue using the same render script.

## 4. Write a cell into the stencil buffer

Mask meshes are already in screen coordinates, so write them using an identity
view and your normal screen projection. Disable color writes while populating
the stencil:

```lua
local function write_cell_stencil(mask_pred, screen_projection)
    render.set_camera()
    render.set_view(vmath.matrix4())
    render.set_projection(screen_projection)
    render.set_color_mask(false, false, false, false)
    render.enable_state(graphics.STATE_STENCIL_TEST)
    render.set_stencil_mask(0xff)
    render.set_stencil_func(graphics.COMPARE_FUNC_ALWAYS, 1, 0xff)
    render.set_stencil_op(
        graphics.STENCIL_OP_KEEP,
        graphics.STENCIL_OP_KEEP,
        graphics.STENCIL_OP_REPLACE)
    render.draw(mask_pred)
    render.set_color_mask(true, true, true, true)
end
```

Before writing each cell, clear only `BUFFER_TYPE_STENCIL_BIT`. Do not clear the
color buffer between cameras.

## 5. Render one camera through one cell

After writing the mask, disable stencil writes, require stencil value `1`, set
the camera, and draw the world:

```lua
local function draw_camera_cell(self, camera_url, mask_pred, screen_projection)
    render.clear({ [graphics.BUFFER_TYPE_STENCIL_BIT] = 0 })
    write_cell_stencil(mask_pred, screen_projection)

    render.set_stencil_mask(0x00)
    render.set_stencil_func(graphics.COMPARE_FUNC_EQUAL, 1, 0xff)
    render.set_stencil_op(
        graphics.STENCIL_OP_KEEP,
        graphics.STENCIL_OP_KEEP,
        graphics.STENCIL_OP_KEEP)

    render.set_camera(camera_url, { use_frustum = true })
    render.draw(self.world_pred)

    -- Optional: actors visible from every camera.
    for _, actor_pred in ipairs(self.actor_preds or {}) do
        render.draw(actor_pred)
    end

    render.set_camera()
    render.disable_state(graphics.STATE_STENCIL_TEST)
end
```

Draw any predicates that belong inside a camera cell here. This may include
tiles, particles, models, or labels. Apply their normal depth, culling, and blend
states exactly as you would in your existing world pass.

## 6. Integrate the passes into `update(self)`

Perform your normal full-frame color/depth/stencil clear once. Set the stencil
write mask back to `0xff` before clearing; a previous camera pass leaves stencil
writes disabled:

```lua
render.set_stencil_mask(0xff)
render.clear({
    [graphics.BUFFER_TYPE_COLOR0_BIT] = clear_color,
    [graphics.BUFFER_TYPE_DEPTH_BIT] = 1,
    [graphics.BUFFER_TYPE_STENCIL_BIT] = 0,
})
```

Then choose the split-screen path only while cameras are active:

```lua
if self.cameras then
    for i = 1, self.camera_count do
        draw_camera_cell(
            self,
            self.cameras[i],
            self.mask_preds[i],
            screen_projection)
    end
else
    draw_your_existing_world(self)
end
```

If you use owner actor passes, render them after all stencil-clipped cells:

```lua
render.disable_state(graphics.STATE_STENCIL_TEST)
for i, actor_pred in ipairs(self.actor_preds) do
    render.set_camera(self.cameras[i], { use_frustum = true })
    render.draw(actor_pred)
end
render.set_camera()
```

Next, return to identity view/screen projection and draw the divider:

```lua
render.set_camera()
render.set_view(vmath.matrix4())
render.set_projection(screen_projection)
render.enable_state(graphics.STATE_BLEND)
render.draw(self.divider_pred)
render.disable_state(graphics.STATE_BLEND)
```

Finally draw debug primitives and GUI using your existing projections. Make
sure stencil testing is disabled, or set it to `COMPARE_FUNC_ALWAYS`, before
drawing screen-space UI. A persistent Back button or HUD should not inherit the
last camera's stencil test.

## 7. Add the controller and cameras to the collection

Add one orthographic camera game object per site. The bundled example uses fixed
orthographic zoom and lets the controller move the camera game objects.

Add the mask meshes, divider mesh, and your controlling script to one game
object. A three-view component layout looks like this:

```text
controller
├── script
├── world
├── mask_1
├── mask_2
├── mask_3
└── divider

camera_1
camera_2
camera_3
```

If you use the optional owner passes, also add one uniquely tagged actor mesh
per player. Dynamic actor meshes must also use independent buffers.

## 8. Create and update the Lua controller

Require the module and supply the camera and resource wiring:

```lua
local split_screen = require("voronoi.voronoi_split_screen")

local function component_url(path, fragment)
    local url = msg.url()
    url.path = hash(path)
    url.fragment = hash(fragment)
    return url
end

self.split_screen = split_screen.create({
    width = 800,
    height = 600,
    camera_paths = {
        "/camera_1",
        "/camera_2",
        "/camera_3",
    },
    camera_urls = {
        component_url("/camera_1", "camera"),
        component_url("/camera_2", "camera"),
        component_url("/camera_3", "camera"),
    },
    mask_resources = {
        go.get("#mask_1", "vertices"),
        go.get("#mask_2", "vertices"),
        go.get("#mask_3", "vertices"),
    },
    divider_resource = go.get("#divider", "vertices"),
    divider_colors = player_colors,
    merge_distance = 150,
    split_distance = 190,
    transition_duration = 0.55,
    merged_site_radius = 0.35,
    camera_zoom = 1.2,
})
```

Pass the latest world-space sites on every frame. There must be one site for
each camera, URL, path, and mask:

```lua
function update(self, dt)
    update_player_positions(self, dt)
    split_screen.update(self.split_screen, self.sites, dt, false)
end
```

Snap the first update so the initial cameras and masks are immediately valid:

```lua
split_screen.update(self.split_screen, self.sites, 0, true)
```

Destroy the controller when its collection unloads. This releases the native
Voronoi context and tells the render script to return to its default path:

```lua
function final(self)
    split_screen.destroy(self.split_screen)
end
```

## Controller options

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `width`, `height` | Yes | — | Screen-space Voronoi bounds. |
| `camera_paths` | Yes | — | Game object paths moved by the controller. |
| `camera_urls` | Yes | — | Camera component URLs sent to the render script. |
| `mask_resources` | Yes | — | Independent mesh vertex-buffer resources. |
| `divider_resource` | Yes | — | Dynamic colored divider buffer. |
| `divider_colors` | No | White | Color per site/view. |
| `merge_distance` | No | `150` | Distance below which groups merge. |
| `split_distance` | No | `190` | Distance above which existing groups split. Keep this larger than `merge_distance`. |
| `transition_duration` | No | `0.55` | Merge/split animation time in seconds. |
| `merged_site_radius` | No | `0.35` | Sub-pixel separation retained between merged sites. |
| `divider_width` | No | `2` | Divider width in screen units. |
| `divider_z` | No | `0.8` | Divider mesh Z coordinate. |
| `camera_zoom` | No | `1` | Zoom used by the default camera-position calculation. |
| `camera_z` | No | `10` | Z coordinate assigned to camera game objects. |
| `camera_position` | No | Centered orthographic calculation | Callback `(state, site, index)` returning a camera position. |
| `render_url` | No | `"@render:"` | Render script message receiver. |
| `set_cameras_message` | No | `"set_voronoi_cameras"` | Camera activation message. |
| `clear_cameras_message` | No | `"clear_voronoi_cameras"` | Camera deactivation message. |

The controller exposes `get_group_count`, `get_transition`,
`get_region_count`, `get_divider_edge_count`, and `get_diagram` for diagnostics
or UI.

## Supporting more than three cameras

The Lua controller accepts matching arrays of sites, camera paths, camera URLs,
and mask resources. The bundled render script and example assets currently
declare three predicates and read `camera_1` through `camera_3` explicitly.

To add more views:

1. Add another independent mask buffer, mesh, and uniquely tagged material.
2. Append its predicate to `self.mask_preds`.
3. Add the camera URL field to the `set_voronoi_cameras` message handler.
4. If using owner passes, add another uniquely tagged actor predicate and
   independent actor buffer.
5. Supply the additional site, path, URL, mask resource, and divider color to
   `split_screen.create()` and `split_screen.update()`.

## Common integration problems

- **A cell shows the wrong camera:** verify that site, camera, mask, and actor
  arrays use the same index ordering.
- **Every mask or actor looks identical:** the meshes are probably sharing one
  mutable buffer resource. Give each dynamic mesh its own `.buffer` file.
- **A seam trails behind the stencil:** render a divider mesh from the
  controller. Do not use queued debug lines as permanent split boundaries.
- **The whole frame is blank:** restore the color mask after writing the
  stencil and ensure the world predicate matches the world materials.
- **Only the last cell is visible:** clear only the stencil buffer between
  camera passes, not the color buffer.
- **GUI is clipped:** disable stencil testing or use `COMPARE_FUNC_ALWAYS`
  before the GUI pass, and clear the active render camera.
- **Merge thresholds flicker:** keep `split_distance` larger than
  `merge_distance`; the gap provides hysteresis.
- **A player is cut at a seam:** use unique actor predicates and the optional
  unstencilled owner-camera pass.

## Further reading

- [Voronoi Split Screen: A Quick Tour](https://mattwoelk.github.io/voronoi_split_screen_notes/)
  covers screen-space sites, gradual separation, divider damping, dead zones,
  and smooth merging.
- [Math for Game Programmers: Juicing Your Cameras With Math](https://gdcvault.com/play/1023146/Math-for-Game-Programmers-Juicing)
  presents camera-smoothing techniques and N-way Voronoi split-screen. The
  accompanying [GDC slides](https://media.gdcvault.com/gdc2016/Presentations/Eiserloh_Squirrel_JuicingYourCameras.pdf)
  include the relevant diagrams and formulas.
- [Godot Dynamic Split Screen demo](https://godotengine.org/asset-library/asset/2806)
  is an open-source viewport-texture and shader implementation. Its source is
  available in the [Godot demo repository](https://github.com/godotengine/godot-demo-projects).
- [Voron_eye](https://www.researchgate.net/publication/370285558_Voron_eye_A_deep_dive_into_video_game_camera_framing_with_multiple_points_of_focus_and_the_exploration_of_the_dynamic_split-screen)
  discusses multi-focus framing, player clustering, shared cameras, and
  multi-way Voronoi layouts.
- [Dynamic viewport merging discussion](https://gamedev.stackexchange.com/questions/25088/how-to-manage-merging-splitting-viewports-to-create-a-dynamic-splitscreen)
  explains why the frames immediately before and after a split topology change
  should be visually identical.
