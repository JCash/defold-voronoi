# defold-voronoi

A small extension for Defold to add 2D voronoi functionality

Uses the C/C++ library [jc_voronoi](https://github.com/JCash/voronoi) which
is a fast C implementation for creating 2D Voronoi diagrams from a point set.
The bundled header is jc_voronoi 0.10.0.
Native extensions depending on this library can include the exported header
with `#include <jc_voronoi.h>`.

Uses [Fortune's sweep algorithm.](https://en.wikipedia.org/wiki/Fortune%27s_algorithm)

Tested on iOS, OSX and Windows (should work fine on Android too)

The app starts at a selection screen. Choose **Voronoi Diagram** or
**Split Screen**; the selected collection is loaded through a collection proxy.
Use the **Back** button in either example to unload it and return to the menu.

In the Voronoi Diagram example, press and drag anywhere to grab the site
belonging to the Voronoi cell under the pointer. The site remains locked to the
pointer until release, while its immediate neighbors are displaced to keep the
grabbed cell close to its original area. Hold Up/Down to continuously add or
remove particles at 60 particles per second.

## Examples

The repository includes two focused example collections:

### Voronoi Diagram

`/examples/voronoi/voronoi.collection`

It creates and animates a dense Voronoi
diagram and supports cell grabbing, continuous particle-count changes, and
grabbed-cell area preservation.

![Voronoi Diagram example](docs/images/voronoi-diagram.png)

### Split Screen

`/examples/multicamera/multicamera.collection`

![Split Screen example](docs/images/split-screen.png)

See [SPLITSCREEN.md](SPLITSCREEN.md) for the example controls, implementation
details, render-script integration guide, and further reading.

# Lua API

This extension adds a Lua module named `voronoi`
and ships editor completion metadata in `/voronoi/voronoi.script_api`.

## voronoi.create(width, height)

Creates, and returns, a voronoi diagram context.

    self.diagram = voronoi.create(800, 600)

## voronoi.destroy(diagram)

Destroys a diagram context

## voronoi.generate(diagram, points)

Generates a 2D voronoi diagram from a set of 2D points
The `points` variable is a table with numbers: `{ x1, y1, x2, y2, ... }`

    local points = { 1.0, 1.5, 2.3, 3.1 }
    voronoi.generate(self.diagram, points } 

After generating the diagram, retrieve the cells with `voronoi.get_regions()`
or `voronoi.get_region()`.

## voronoi.get_num_regions(diagram)

Returns the number of valid sites. Note that some sites might
have been removed since they were duplicates.

## voronoi.get_region(diagram, index)

Gets a site and it's information.

- `index` - the index of the site in the original set of points

- `x` - the x value of the site's position

- `y` - the y value of the site's position

- `area` - the area of the voronoi cell

- `edges` - a list of the neighboring edges, where each edge is a table
and contains:

-- '1' = `{ x, y }` - The first point of the edge

-- '2' = `{ x, y }` - The second point of the edge

-- 'neighbor' - the index of the neighbor in the original set of points


Note that the edges are sorted, and are always rotated counter clockwise around the current site.

Here is an example of how to iterate the generated diagram:

    local num_regions = voronoi.get_num_regions(self.diagram)
    for i=1,num_regions do
        local site = voronoi.get_region(self.diagram, i)
        for ei, edge in pairs(site.edges) do
            if edge.neighbor > 0 then
                ...
            end
        end
    end

## voronoi.get_debug_image(diagram)

Gets an rgb image showing the diagram. The image is a buffer with the signature `{hash("rgb"), buffer_VALUE_TYPE_UINT8, 3}`

    self.textureheader = {width=self.width,
                        height=self.height,
                        type=graphics.TEXTURE_TYPE_2D,
                        format=graphics.TEXTURE_FORMAT_RGB }
    local path = go.get("#sprite", "texture0")
    local image = voronoi.get_debug_image(self.diagram)
    resource.set_texture(path, self.textureheader, image)
