// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// Manage C-cached subscript arrays for speed

#ifndef CACHEARRAY_H
#define CACHEARRAY_H

int cachearray(lua_State *L);
int cachearray_generate(lua_State *L);
int cachearray_tostring(lua_State *L);

#endif // CACHEARRAY_H
