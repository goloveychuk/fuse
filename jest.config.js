/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testMatch: ['**/sources/__tests__/**/*.test.ts'],
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: {
    '^.+\\.ts$': ['ts-jest', { tsconfig: { module: 'commonjs', strict: true, esModuleInterop: true, target: 'ES2019', skipLibCheck: true } }],
  },
  moduleNameMapper: {
    // @yarnpkg/core uses es-toolkit/compat but the CJS compat build is not
    // shipped in the installed version — stub the two functions it needs.
    '^es-toolkit/compat$': '<rootDir>/es-toolkit-compat-stub.js',
  },
};
