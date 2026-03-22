const express = require("express");
const app = express();

app.get("/", (_, res) => {
  res.send("Hello from Kubernetes");
});

// Readiness probe — if your app has a DB or external dependency,
// check its connectivity here instead of just returning 200.
app.get("/healthz", (_, res) => {
  res.sendStatus(200);
});

const port = process.env.PORT;
app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
