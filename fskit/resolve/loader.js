const { createRequire, registerHooks } = require('node:module');
const { pathToFileURL } = require('node:url');

registerHooks({ resolve: (spec, ctx, nextResolve) => {
    if (spec === 'alias' ) {
        console.log('resolve', spec);
        return {
            shortCircuit: true,
            url: 'file:///Users/vadymh/github/fskit/FSKitSample/resolve/node_modules/react/index.js'
        }
    }
    return nextResolve(spec, ctx);
} });

// const userRequire = createRequire(__filename);

// The synchronous hooks affect import, require() and user require() function
// created through createRequire().
// import('./my-app.js');
// require.resolve('alias');
// userRequire('./my-app-3.js');