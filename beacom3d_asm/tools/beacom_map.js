// Builds maps/beacom/{basement,ground,second}.txt: the Beacom Institute of
// Technology (Dakota State University, Madison SD) as far as the public record
// describes it. Run from beacom3d_asm/:  node tools/beacom_map.js
//
// What's from sources (see README "The real Beacom"):
//   * two storeys, ~31,300 sq ft, a rectangle running north-south (east of
//     Washington Ave, between Emry Hall and Girton House)
//   * glass entry opening onto a large, two-storey collaboration space
//   * a media wall of 25 55-inch TVs (5 x 5)
//   * a grand staircase at the SOUTH end of the collaboration space, with
//     bleachers built into it and a stage halfway up (wood panels)
//   * 2nd floor: the "cyber ops room" and collaboration pods float over the
//     collaboration space; labs have glass walls onto the hallways
//   * 2nd floor, NORTH end: the glass-walled Academic Server Room (13 x 26 ft)
//     between two large classrooms, on a raised floor
//   * rooms 112, 114, 117 (1st floor), 213, 231, 233, 235 (2nd floor);
//     235 is the conference room; the Beacom College offices
// What's reconstructed / invented (no public floor plan exists): exact room
// positions and sizes, restrooms, the back stair, and the whole sub-level
// (the building has no known basement -- the game's third storey is fiction).
//
// Grid: 59 x 31 cells of 2 m, row 0 = north. The building is x 20..39,
// rows 0..30 (walls included): 36 m x 58 m inside, about 1.4x the real floor
// area, so there is room to play. Legend as in world.asm, plus
//   g glass wall (see-through)   W media wall   b floor under the grand stair
const fs = require("fs");
const W = 59, H = 31;
const floors = [0, 1, 2].map(() => Array.from({ length: H }, () => Array(W).fill("#")));
function put(f, x, y, c) { floors[f][y][x] = c; }
function fill(f, x0, y0, x1, y1, c) { for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) put(f, x, y, c); }
function box(f, x0, y0, x1, y1, c) {           // walls round a rectangle
  for (let x = x0; x <= x1; x++) { put(f, x, y0, c); put(f, x, y1, c); }
  for (let y = y0; y <= y1; y++) { put(f, x0, y, c); put(f, x1, y, c); }
}
function desks(f, x0, y0, x1, y1) {             // rows of desks, aisles between
  for (let y = y0; y <= y1; y += 2) for (let x = x0; x <= x1; x++) if ((x - x0) % 4 !== 3) put(f, x, y, "d");
}

// ---------------------------------------------------------------- 1st floor
{
  const f = 1;
  fill(f, 21, 1, 38, 29, " ");
  box(f, 20, 0, 39, 30, "H");
  fill(f, 20, 11, 20, 20, "g");                 // the glass entry, facing Washington Ave
  // north wing: 117 (the big room -- presentations happen here), 112, 114
  box(f, 20, 0, 28, 8, "C"); box(f, 20, 0, 39, 30, "H");
  fill(f, 21, 1, 27, 7, " "); put(f, 28, 4, " ");
  desks(f, 23, 2, 26, 6);
  put(f, 22, 3, ".");                           // maintenance hatch (ladder from the sub-level)
  box(f, 31, 0, 39, 4, "C"); box(f, 31, 4, 39, 8, "C"); box(f, 20, 0, 39, 30, "H");
  fill(f, 32, 1, 38, 3, " "); fill(f, 32, 5, 38, 7, " ");
  put(f, 31, 2, " "); put(f, 31, 6, " ");
  desks(f, 33, 2, 37, 2); desks(f, 33, 6, 37, 6);
  // the collaboration space (two storeys tall: see the 2nd floor)
  fill(f, 21, 9, 34, 22, " ");
  fill(f, 35, 9, 35, 22, "C");
  fill(f, 35, 14, 35, 16, "W");                 // the media wall, 5 x 5 TVs, facing the entry
  // collaboration furniture: tables to vault
  for (const [x, y] of [[23, 11], [24, 11], [31, 11], [32, 11], [23, 17], [24, 17]]) put(f, x, y, "d");
  put(f, 32, 18, "B");                          // B, holding court in the performance area
  // the grand staircase / bleachers (solid wooden steps: world.asm platforms)
  fill(f, 24, 20, 31, 22, "b");
  // service strip: restroom (safe room), service landing, stair down to the sub-level
  box(f, 35, 8, 39, 11, "N"); fill(f, 36, 9, 38, 10, "S"); put(f, 35, 10, "S");
  box(f, 20, 0, 39, 30, "H");
  fill(f, 36, 12, 38, 13, " "); put(f, 35, 12, " ");
  fill(f, 37, 14, 38, 19, ".");                 // over the stair down
  fill(f, 36, 14, 36, 22, "C"); fill(f, 37, 20, 38, 22, "C");
  // south wing: corridor, game design lab and animation lab (glass fronts)
  fill(f, 21, 23, 38, 23, " ");
  fill(f, 21, 24, 27, 24, "g"); fill(f, 28, 24, 28, 29, "C");
  fill(f, 29, 24, 33, 24, "g"); fill(f, 34, 24, 34, 29, "C");
  put(f, 24, 24, " "); put(f, 31, 24, " ");
  desks(f, 22, 26, 26, 28); desks(f, 30, 26, 32, 28);
  // back stair (up, rising north) with its corridor
  fill(f, 35, 24, 35, 29, " ");
  fill(f, 36, 24, 38, 24, "C"); fill(f, 36, 25, 36, 28, "C"); put(f, 36, 29, " ");
  fill(f, 37, 25, 38, 29, "^");
}

// ---------------------------------------------------------------- 2nd floor
{
  const f = 2;
  fill(f, 21, 1, 38, 29, " ");
  box(f, 20, 0, 39, 30, "H");
  fill(f, 20, 9, 20, 22, "g");                  // the glass rises the full two storeys
  // north: classroom 231 | Academic Server Room (glass) | classroom 233
  box(f, 20, 0, 27, 7, "C"); fill(f, 21, 1, 26, 6, " "); put(f, 24, 7, " ");
  desks(f, 22, 2, 25, 5);
  box(f, 28, 0, 31, 6, "g"); fill(f, 29, 1, 30, 5, " ");
  fill(f, 29, 2, 29, 5, "R"); put(f, 30, 6, " ");
  box(f, 32, 0, 39, 7, "C"); fill(f, 33, 1, 38, 6, " "); put(f, 35, 7, " ");
  desks(f, 34, 2, 37, 5);
  box(f, 20, 0, 39, 30, "H");
  fill(f, 28, 7, 31, 7, " ");                   // lobby in front of the server room
  fill(f, 21, 8, 38, 8, " ");                   // the north balcony
  // open to the collaboration space below...
  fill(f, 21, 9, 34, 22, ".");
  // ...with collaboration pods floating out over it
  fill(f, 21, 9, 22, 10, " ");
  fill(f, 33, 18, 34, 19, " ");
  // the cyber ops room, floating in the middle, glass all round, on a bridge
  box(f, 25, 12, 30, 16, "g"); fill(f, 26, 13, 29, 15, " ");
  put(f, 26, 13, "d"); put(f, 27, 13, "d"); put(f, 28, 15, "d"); put(f, 29, 15, "d");
  put(f, 30, 14, " "); fill(f, 31, 14, 34, 14, " ");
  // east walkway along the media wall
  fill(f, 35, 9, 38, 22, " ");
  // south: 213, the Beacom College office (safe room), 235 conference room
  fill(f, 21, 23, 38, 23, " ");
  box(f, 20, 24, 27, 30, "C"); fill(f, 21, 25, 26, 29, " "); put(f, 24, 24, " ");
  desks(f, 22, 26, 25, 28);
  box(f, 27, 24, 33, 30, "N"); fill(f, 28, 25, 32, 29, "S"); put(f, 30, 24, "S");
  box(f, 33, 24, 36, 30, "C"); fill(f, 34, 25, 35, 29, " "); put(f, 34, 24, " ");
  put(f, 34, 27, "d");                          // (one desk: the room is only 2 wide)
  box(f, 20, 0, 39, 30, "H");
  fill(f, 37, 24, 38, 24, " ");                 // where the back stair arrives
  fill(f, 37, 25, 38, 29, ".");
  fill(f, 36, 25, 36, 29, "C");
}

// ------------------------------------------------ the sub-level (fiction)
{
  const f = 0;
  // mechanical hall under the south of the building: Y's cage, the boiler
  fill(f, 21, 20, 38, 28, " ");
  fill(f, 37, 14, 38, 19, "^");                 // stair up to the service landing
  for (const [x, y] of [[24, 23], [29, 23], [34, 23], [24, 26], [34, 26]]) put(f, x, y, "P");
  fill(f, 26, 26, 29, 26, "Y");
  for (const [x, y, c] of [[31, 21, "k"], [32, 21, "K"], [22, 28, "k"], [36, 27, "K"]]) put(f, x, y, c);
  // utility tunnels: a loop out under the campus
  fill(f, 3, 2, 34, 3, " ");                    // north tunnel
  fill(f, 33, 4, 34, 19, " ");                  // east connector down to the hall
  fill(f, 3, 4, 4, 28, " ");                    // west tunnel
  fill(f, 5, 27, 20, 28, " ");                  // south tunnel into the hall
  fill(f, 5, 14, 20, 15, " ");                  // cross tunnel
  put(f, 22, 3, "u");                           // ladder up to the hatch in room 117
  fill(f, 21, 2, 23, 3, " "); put(f, 22, 3, "u");
  // electrical room: the sub-level's safe room
  box(f, 10, 17, 16, 22, "N"); fill(f, 11, 18, 15, 21, "S"); put(f, 13, 17, "S");
  fill(f, 13, 16, 13, 16, " ");
  // a storeroom full of crates off the west tunnel
  fill(f, 6, 5, 12, 10, " "); put(f, 5, 7, " ");   // (its door)
  for (const [x, y, c] of [[8, 6, "k"], [9, 6, "K"], [11, 8, "k"], [7, 9, "K"]]) put(f, x, y, c);
}

fs.mkdirSync("maps/beacom", { recursive: true });
const names = ["basement", "ground", "second"];
floors.forEach((g, i) => fs.writeFileSync(`maps/beacom/${names[i]}.txt`, g.map(r => r.join("")).join("\n") + "\n"));
for (let i = 2; i >= 0; i--) { console.log(`== ${names[i]}`); floors[i].forEach((r, y) => console.log(String(y).padStart(2), r.slice(0, 42).join(""))); }
