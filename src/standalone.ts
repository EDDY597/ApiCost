import { createServer } from "node:http"
import { createHandler, loadFileConfig } from "./gateway.ts"

const fileConfig = loadFileConfig() ?? {}

if (!process.env.OPENCODE_GO_API_KEY && fileConfig.apiKey) {
  process.env.OPENCODE_GO_API_KEY = String(fileConfig.apiKey)
}
if (!process.env.OPENCODE_GO_GATEWAY_PORT && fileConfig.port) {
  process.env.OPENCODE_GO_GATEWAY_PORT = String(fileConfig.port)
}
if (!process.env.OPENCODE_GO_GATEWAY_HOST && fileConfig.hostname) {
  process.env.OPENCODE_GO_GATEWAY_HOST = String(fileConfig.hostname)
}
if (!process.env.OPENCODE_GO_GATEWAY_TOKEN && fileConfig.token) {
  process.env.OPENCODE_GO_GATEWAY_TOKEN = String(fileConfig.token)
}

const { handler } = createHandler({})
const hostname = process.env.OPENCODE_GO_GATEWAY_HOST ?? "127.0.0.1"
const parsedPort = Number(process.env.OPENCODE_GO_GATEWAY_PORT ?? 8787)
const port = Number.isFinite(parsedPort) && parsedPort > 0 ? parsedPort : 8787

const server = createServer(async (request, response) => {
  try {
    const url = `http://${request.headers.host ?? `${hostname}:${port}`}${request.url ?? "/"}`
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(chunk as Buffer)
    const body = chunks.length ? Buffer.concat(chunks) : undefined
    const webRequest = new Request(url, {
      method: request.method,
      headers: request.headers as any,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : body,
    })
    const webResponse = await handler(webRequest)
    response.statusCode = webResponse.status
    webResponse.headers.forEach((value, key) => response.setHeader(key, value))
    if (webResponse.body) {
      const reader = webResponse.body.getReader()
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        response.write(Buffer.from(value))
      }
    }
    response.end()
  } catch (error: any) {
    response.statusCode = 500
    response.setHeader("content-type", "application/json")
    response.end(JSON.stringify({ error: { message: error?.message ?? "server error" } }))
  }
})

server.on("error", (error: any) => {
  if (error?.code === "EADDRINUSE") {
    console.error(`Port ${port} is already in use. Set OPENCODE_GO_GATEWAY_PORT or gateway.config.json "port".`)
    process.exit(1)
  }
  console.error(error)
  process.exit(1)
})

server.listen(port, hostname, () => {
  console.log(`OpenCode Go gateway listening on http://${hostname}:${port}/v1`)
})
