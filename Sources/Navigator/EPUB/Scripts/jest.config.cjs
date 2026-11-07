module.exports = {
  transform: {
    "^.+\\.[jt]s$": "babel-jest",
  },
  testMatch: ["**/*.test.ts"],
  testEnvironment: "jsdom",
};
