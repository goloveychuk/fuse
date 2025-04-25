const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { performance } = require('perf_hooks');
// Path to directory we want to read
const nodeModulesPath = '/Users/vadymh/work/responsive-editor2/node_modules';

const dirs = fs.readdirSync(nodeModulesPath, { withFileTypes: true }).map(dir => {

    const dirPath = path.join(nodeModulesPath, dir.name);

    return pathToFileURL(dirPath).href
})

// console.log(dirs);


let find = 'file:///Users/vadymh/work/responsive-editor2/node_modules/acorn-node/sfdas.js';


let map = new Map()

let ind = 0
for (const dir of dirs) {
    let prev = { children: map }
    for (let segment of dir.split('/')) {
        if (!prev.children.has(segment)) {
            prev.children.set(segment, { entries: [], children: new Map() })
        }
        prev = prev.children.get(segment)
    }
    prev.entries.push(ind)
    ind++
}

const start = performance.now();




for (let i = 0; i < 500_000; i++) {
    // for (const dir of dirs) {
    //     if (find.startsWith(dir)) {
    //         break;
    //     }
    // }
    let prev = { children: map, entries: [] }

    let min = Infinity

    // let prevind = 0
    // for (let ind = 0; ind < find.length; ind++) {
    //     if (find[ind] === '/') {
    //         const segment = find.slice(prevind, ind)
    //         prevind = ind + 1
    //         if (!prev.children.has(segment)) {
    //             break;
    //         }
    //         for (const e of prev.entries) {
    //             if (e < min) {
    //                 min = e
    //             }
    //         }
    //         prev = prev.children.get(segment)
    //     }
    // }
    for (const segment of find.split('/')) {
        if (!prev.children.has(segment)) {
            break;
        }
        for (const e of prev.entries) {
            if (e < min) {
                min = e
            }
        }
        prev = prev.children.get(segment)
    }
    for (const e of prev.entries) {
        if (e < min) {
            min = e
        }
    }
    if (min === Infinity) {
        throw new Error('Not found')
    }
    // debugger
}

const end = performance.now();
console.log(`Execution time: ${end - start} milliseconds`);