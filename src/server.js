import { createServer } from "node:http";
import { handle } from "./app.js";

createServer(handle).listen(8080, () => console.log("hostyour-demo-consumer listens on 8080"));
