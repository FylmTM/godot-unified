package survivor

import "unified:sim"

GRID_CELL :: 2 // m
GRID_N :: 30 // cells along each axis: 60 m, the arena inside its walls
GRID_CELLS :: GRID_N * GRID_N
GRID_ORIGIN :: -GRID_N * GRID_CELL / 2 // the grid's corner (x and z)

// The alive enemies in GRID_CELL cells (scratch, rebuilt when a pass needs it): the enemies near a point are those in
// its cell and the 8 around it (sim.grid_near), each cell in index order. A position outside the grid counts in its
// edge cell.
Enemy_Grid :: sim.Grid(GRID_CELLS, MAX_ENEMIES)

// Rebuilds the grid from the enemies, walked in index order.
enemy_grid_build :: proc(grid: ^Enemy_Grid, enemies: ^sim.Table(Enemy, MAX_ENEMIES)) {
	sim.grid_begin(grid, {GRID_ORIGIN, GRID_ORIGIN}, GRID_CELL, GRID_N, GRID_N)
	alive := sim.iterate(enemies)
	for enemy, handle in sim.next(&alive) do sim.grid_add(grid, i32(handle.index), enemy.pos)
	sim.grid_end(grid)
}
