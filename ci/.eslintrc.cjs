module.exports = {
  root: true,
  env: { browser: true, es2021: true, node: true },
  extends: [],
  parserOptions: { ecmaVersion: "latest", sourceType: "module" },
  ignorePatterns: ["node_modules/", "vendor/", "dist/", "build/"],
  rules: {
    // Keep defaults light; real projects usually supply their own ESLint config.
    "no-unused-vars": ["warn", { argsIgnorePattern: "^_" }]
  }
};
