#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#if !defined(DM_PLATFORM_WINDOWS)
#include <unistd.h>
#endif

#define EXTENSION_NAME Voronoi
#define LIB_NAME "Voronoi"
#define LUA_MODULE_NAME "voronoi"

// Defold SDK
#define DLIB_LOG_DOMAIN LIB_NAME
#include <dmsdk/sdk.h>

#define JC_VORONOI_IMPLEMENTATION
#include "jc_voronoi.h"

extern void draw_triangle(const jcv_point* v0, const jcv_point* v1, const jcv_point* v2, unsigned char* image, int width, int height, int nchannels, unsigned char* color);

struct VoronoiContext
{
    jcv_diagram m_Diagram;
    jcv_point* m_Points;
    int m_NumPoints;
    int m_Width;
    int m_Height;

    dmBuffer::HBuffer m_Buffer;
    int m_BufferRef;
};

static VoronoiContext* CheckVoronoiDiagram(lua_State* L, int index)
{
    if( !lua_isuserdata(L, 1) )
    {
        luaL_typerror(L, 1, "diagram");
        return 0;
    }
    return (VoronoiContext*)lua_touserdata(L, 1);
}

static int Create(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);
    int width = luaL_checkint(L, 1);
    int height = luaL_checkint(L, 2);

    VoronoiContext* ctx = (VoronoiContext*) malloc( sizeof(VoronoiContext) );
    memset(ctx, 0, sizeof(VoronoiContext));
    ctx->m_Width = width;
    ctx->m_Height = height;

    lua_pushlightuserdata(L, ctx);
    return 1;   
}

static int Destroy(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);
    VoronoiContext* ctx = CheckVoronoiDiagram(L, 1);

    if(ctx->m_Buffer != 0)
    {
        // We want it destroyed by the GC
        dmScript::Unref(L, LUA_REGISTRYINDEX, ctx->m_BufferRef);
    }

    if(ctx->m_Points)
    {
        free(ctx->m_Points);
    }
    free(ctx);
    return 0;
}

static int Generate(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);

    VoronoiContext* ctx = CheckVoronoiDiagram(L, 1);

    int num_sites = 0;
    if(lua_istable(L, 2))
    {
        num_sites = (int)lua_objlen(L, 2) / 2;
    }   
    /*
    else if(dmScript::IsBuffer(L, 2))
    {

    }*/
    else
    {
        return luaL_typerror(L, 2, "table");
    }

    if( ctx->m_NumPoints == 0 )
    {
        ctx->m_NumPoints = num_sites;
        ctx->m_Points = (jcv_point*) malloc( sizeof(jcv_point) * ctx->m_NumPoints );
    }
    else if( num_sites != ctx->m_NumPoints )
    {
        return luaL_error(L, "You must not change number of points after creation");
    }

    if(lua_istable(L, 2))
    {
        float* values = (float*)ctx->m_Points;

        lua_pushvalue(L, 2);
        lua_pushnil(L);
        while (lua_next(L, -2))
        {
            *values = (float)lua_tonumber(L, -1);
            ++values;
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }

    memset(&ctx->m_Diagram, 0, sizeof(jcv_diagram));

    jcv_rect rect = {(jcv_real)0, (jcv_real)0, (jcv_real)ctx->m_Width, (jcv_real)ctx->m_Height};
	jcv_diagram_generate(ctx->m_NumPoints, ctx->m_Points, &rect, &ctx->m_Diagram);
    //jcv_diagram_generate(ctx->m_NumPoints, ctx->m_Points, ctx->m_Width, ctx->m_Height, &ctx->m_Diagram );

    return 0;
}


static int Relax(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);

    VoronoiContext* ctx = CheckVoronoiDiagram(L, 1);

    jcv_point* points = ctx->m_Points;
    const jcv_site* sites = jcv_diagram_get_sites(&ctx->m_Diagram);

    for( int i = 0; i < ctx->m_Diagram.numsites; ++i )
    {
        const jcv_site* site = &sites[i];
        jcv_point sum = site->p;
        int count = 1;

        const jcv_graphedge* edge = site->edges;

        while( edge )
        {
            sum.x += edge->pos[0].x;
            sum.y += edge->pos[0].y;
            ++count;
            edge = edge->next;
        }

        points[site->index].x = sum.x / count;
        points[site->index].y = sum.y / count;
    }

    return 0;
}

static int GetSite(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);

    VoronoiContext* ctx = CheckVoronoiDiagram(L, 1);

    int index = luaL_checkint(L, 2);
    if(index < 1 || index >= ctx->m_Diagram.numsites+1)
    {
        return luaL_error(L, "Index '%d' out of range [1, %d)", index, ctx->m_Diagram.numsites+1);
    }
    index--;

    const jcv_site* sites = jcv_diagram_get_sites( &ctx->m_Diagram );
    const jcv_site* site = &sites[index];

    lua_newtable(L);
    
    lua_pushnumber(L, site->p.x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, site->p.y);
    lua_setfield(L, -2, "y");
    lua_pushinteger(L, site->index+1);
    lua_setfield(L, -2, "index");

    lua_pushstring(L, "edges");
    lua_newtable(L);

    float area = 0;
    int edgeindex = 0;
    const jcv_graphedge* e = site->edges;
    while( e )
    {
        lua_pushnumber(L, ++edgeindex);
        lua_newtable(L);

        for( int i = 0; i < 2; ++i )
        {
            lua_pushnumber(L, i+1);
            lua_newtable(L);

            lua_pushnumber(L, e->pos[i].x);
            lua_setfield(L, -2, "x");
            lua_pushnumber(L, e->pos[i].y);
            lua_setfield(L, -2, "y");

            lua_settable(L, -3);
        }

        area += e->pos[0].x * e->pos[1].y - e->pos[0].y * e->pos[1].x;
        
        lua_pushinteger(L, e->neighbor ? e->neighbor->index+1 : 0);
        lua_setfield(L, -2, "neighbor");

        lua_settable(L, -3);

        e = e->next;
    }

    lua_settable(L, -3);

    lua_pushnumber(L, area * 0.5f);
    lua_setfield(L, -2, "area");

    return 1;
}

static void DrawCells(const jcv_diagram* diagram, uint8_t* image, int width, int height)
{
    const jcv_site* sites = jcv_diagram_get_sites( diagram );
    for( int i = 0; i < diagram->numsites; ++i )
    {
        const jcv_site* site = &sites[i];

        srand((unsigned int)site->index); // for generating colors for the triangles

        unsigned char color_tri[3];
        unsigned char basecolor = 120;
        color_tri[0] = basecolor + (unsigned char)(rand() % (235 - basecolor));
        color_tri[1] = basecolor + (unsigned char)(rand() % (235 - basecolor));
        color_tri[2] = basecolor + (unsigned char)(rand() % (235 - basecolor));

        const jcv_graphedge* e = site->edges;
        while( e )
        {
            draw_triangle( &site->p, &e->pos[0], &e->pos[1], image, width, height, 3, color_tri);
            e = e->next;
        }
    }
}

static int GetNumSites(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);
    VoronoiContext* ctx = (VoronoiContext*)lua_touserdata(L, 1);
    lua_pushinteger(L, ctx->m_NumPoints);
    return 1;   
}

static int GetDebugImage(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);
    VoronoiContext* ctx = (VoronoiContext*)lua_touserdata(L, 1);

    if( ctx->m_NumPoints == 0 )
    {
        lua_pushnil(L);
        return 1;
    }

    if(ctx->m_Buffer == 0)
    {
        const dmBuffer::StreamDeclaration streams_decl[] = {
            {dmHashString64("rgb"), dmBuffer::VALUE_TYPE_UINT8, 3},
        };

        dmBuffer::Result r = dmBuffer::Create(ctx->m_Width*ctx->m_Height, streams_decl, 1, &ctx->m_Buffer);
        if (r != dmBuffer::RESULT_OK)
        {
            lua_pushnil(L);
            return 1;
        }

        // Increase ref count
		dmScript::LuaHBuffer luabuf = { ctx->m_Buffer, true };
		dmScript::PushBuffer(L, luabuf);
        ctx->m_BufferRef = dmScript::Ref(L, LUA_REGISTRYINDEX);
    }

    uint8_t* data;
    uint32_t datasize;
    dmBuffer::GetBytes(ctx->m_Buffer, (void**)&data, &datasize);

    DrawCells(&ctx->m_Diagram, data, ctx->m_Width, ctx->m_Height);

    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->m_BufferRef);
    return 1;
}

static const luaL_reg Module_methods[] =
{
    {"create", Create},
    {"destroy", Destroy},
    {"generate", Generate},
    //{"relax", Relax},
    {"get_num_sites", GetNumSites},
    {"get_site", GetSite},
    {"get_debug_image", GetDebugImage},
    {0, 0}
};

static void LuaInit(lua_State* L)
{
    int top = lua_gettop(L);
    luaL_register(L, LUA_MODULE_NAME, Module_methods);

    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}

dmExtension::Result AppInitializeVoronoi(dmExtension::AppParams* params)
{
    return dmExtension::RESULT_OK;
}

dmExtension::Result InitializeVoronoi(dmExtension::Params* params)
{
    LuaInit(params->m_L);
    return dmExtension::RESULT_OK;
}

dmExtension::Result AppFinalizeVoronoi(dmExtension::AppParams* params)
{
    return dmExtension::RESULT_OK;
}

dmExtension::Result FinalizeVoronoi(dmExtension::Params* params)
{
    return dmExtension::RESULT_OK;
}


DM_DECLARE_EXTENSION(EXTENSION_NAME, LIB_NAME, AppInitializeVoronoi, AppFinalizeVoronoi, InitializeVoronoi, 0, 0, FinalizeVoronoi)
