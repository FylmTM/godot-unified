package survivor

import "unified:dmath"
import "unified:sim"

GRID_CELL :: 2 // m
GRID_N :: 30 // cells along each axis: 60 m, the arena inside its walls
GRID_CELLS :: GRID_N * GRID_N
GRID_ORIGIN :: -GRID_N * GRID_CELL / 2 // the grid's corner (x and z)

// The alive enemies sorted into GRID_CELL cells by a counting sort (scratch, rebuilt when a pass needs it): the
// enemies near a point are those in its cell and the 8 around it, each cell in index order. A position outside the
// grid counts in its edge cell.
Grid :: struct {
	cell_start: [GRID_CELLS + 1]i32, // cell c's enemies are items[cell_start[c] ..< cell_start[c + 1]]
	items:      [MAX_ENEMIES]i32, // enemy indices, by cell
	cell_count: [GRID_CELLS]i32,
	enemy_cell: [MAX_ENEMIES]i32, // -1: a free slot
}

grid_cell :: #force_inline proc(pos: [2]f32) -> (cell_x, cell_z: i32) {
	cell_x = dmath.to_i32_clamped((pos.x - GRID_ORIGIN) / GRID_CELL, 0, GRID_N - 1)
	cell_z = dmath.to_i32_clamped((pos.y - GRID_ORIGIN) / GRID_CELL, 0, GRID_N - 1)
	return
}

grid_build :: proc(grid: ^Grid, enemies: ^sim.Table(Enemy, MAX_ENEMIES)) {
	grid.cell_count = {}
	for i in 0 ..< enemies.high_water {
		grid.enemy_cell[i] = -1
	}
	alive := sim.iterate(enemies)
	for enemy, handle in sim.next(&alive) {
		cell_x, cell_z := grid_cell(enemy.pos)
		cell := cell_z * GRID_N + cell_x
		grid.enemy_cell[handle.index] = cell
		grid.cell_count[cell] += 1
	}
	sum: i32 = 0
	for cell in 0 ..< GRID_CELLS {
		grid.cell_start[cell] = sum
		sum += grid.cell_count[cell]
	}
	grid.cell_start[GRID_CELLS] = sum
	grid.cell_count = {} // reused as the fill cursor
	for i in 0 ..< enemies.high_water {
		if cell := grid.enemy_cell[i]; cell >= 0 {
			grid.items[grid.cell_start[cell] + grid.cell_count[cell]] = i32(i)
			grid.cell_count[cell] += 1
		}
	}
}

// The enemies in the 3×3 cells around `pos`, as three rows: the three cells of a row are one contiguous run of `items`
// (empty above and below the grid).
grid_near :: #force_inline proc(grid: ^Grid, pos: [2]f32) -> (rows: [3][]i32) {
	cell_x, cell_z := grid_cell(pos)
	first_x, last_x := dmath.max(cell_x - 1, 0), dmath.min(cell_x + 1, GRID_N - 1)
	for row in 0 ..< i32(3) {
		near_z := cell_z - 1 + row
		if near_z >= 0 && near_z < GRID_N {
			rows[row] = grid.items[grid.cell_start[near_z * GRID_N + first_x]:grid.cell_start[near_z * GRID_N + last_x + 1]]
		}
	}
	return
}
