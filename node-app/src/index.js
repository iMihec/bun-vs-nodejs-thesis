import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import bcrypt from 'bcryptjs';
import { PrismaClient } from '@prisma/client';
import { performance } from 'node:perf_hooks';

const initializationStart = performance.now();

const PORT = Number(process.env.PORT || 3000);
const RUNTIME = process.env.RUNTIME_NAME || 'node';

const DATA_DIR = process.env.DATA_DIR || path.resolve('data');
const READ_FILE_PATH = path.join(DATA_DIR, 'test-10mb.txt');
const WRITE_DIR = path.join(DATA_DIR, 'temp');

const MAX_JSON_BODY_SIZE = 15 * 1024 * 1024;

const WRITE_DATA = Buffer.alloc(2 * 1024 * 1024, 66);

const TEST_PASSWORD = 'diploma-benchmark-test-password';
const TEST_HASH = bcrypt.hashSync(TEST_PASSWORD, 8);



if (!fs.existsSync(DATA_DIR)) {
  throw new Error(`Podatkovna mapa ne obstaja: ${DATA_DIR}`);
}

if (!fs.existsSync(WRITE_DIR)) {
  fs.mkdirSync(WRITE_DIR, { recursive: true });
}

const prisma = new PrismaClient();

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload);

  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    Connection: 'keep-alive'
  });

  res.end(body);
}

function readRequestBody(req, maxSize = MAX_JSON_BODY_SIZE) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let receivedBytes = 0;
    let finished = false;

    req.on('data', chunk => {
      if (finished) {
        return;
      }

      receivedBytes += chunk.length;

      if (receivedBytes > maxSize) {
        finished = true;
        reject(new Error('REQUEST_BODY_TOO_LARGE'));
        req.destroy();
        return;
      }

      chunks.push(chunk);
    });

    req.on('end', () => {
      if (!finished) {
        finished = true;
        resolve(Buffer.concat(chunks).toString('utf8'));
      }
    });

    req.on('error', error => {
      if (!finished) {
        finished = true;
        reject(error);
      }
    });
  });
}

const COMPUTE_SEED = 123456789;
const COMPUTE_ARRAY_SIZE = 500000;
const COMPUTE_MATH_ITERATIONS = 100000;

function createDeterministicRandom(seed) {
  let state = seed >>> 0;

  return function () {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;

    return (state >>> 0) / 4294967296;
  };
}

function runCpuTask() {
  const values = new Array(COMPUTE_ARRAY_SIZE);

  const random = createDeterministicRandom(COMPUTE_SEED);

  for (let i = 0; i < values.length; i++) {
    values[i] = Math.floor(
      random() * COMPUTE_ARRAY_SIZE
    );
  }

  values.sort((a, b) => a - b);

  let sum = 0;

  for (let i = 0; i < COMPUTE_MATH_ITERATIONS; i++) {
    sum += Math.sqrt(i) * Math.sin(i);
  }

  return {
    sortedLength: values.length,
    mathSum: sum
  };
}

async function handleSimple(req, res) {
  sendJson(res, 200, {
    status: 'ok',
    runtime: RUNTIME
  });
}

async function handleCompute(req, res) {
  const result = runCpuTask();

  sendJson(res, 200, {
    status: 'ok',
    runtime: RUNTIME,
    data: result
  });
}

async function handleFileRead(req, res) {
  try {
    const data = await fs.promises.readFile(READ_FILE_PATH);

    sendJson(res, 200, {
      status: 'ok',
      runtime: RUNTIME,
      bytesRead: data.length
    });
  } catch (error) {
    console.error('[FILE READ ERROR]', error);

    sendJson(res, 500, {
      status: 'error',
      error: 'Failed to read file'
    });
  }
}

async function handleFileWrite(req, res) {
  const fileName =
    `${RUNTIME}_write_${Date.now()}_` +
    `${process.hrtime.bigint()}_${Math.random().toString(16).slice(2)}.tmp`;

  const filePath = path.join(WRITE_DIR, fileName);

  try {
    await fs.promises.writeFile(filePath, WRITE_DATA);

    sendJson(res, 200, {
      status: 'ok',
      runtime: RUNTIME,
      bytesWritten: WRITE_DATA.length
    });
  } catch (error) {
    console.error('[FILE WRITE ERROR]', error);

    sendJson(res, 500, {
      status: 'error',
      error: 'Write failed'
    });
  }
}

async function handleJson(req, res) {
  try {
    const body = await readRequestBody(req);
    const parsed = JSON.parse(body);

    const items = Array.isArray(parsed)
      ? parsed
      : Array.isArray(parsed.items)
        ? parsed.items
        : [];

    let processedCount = 0;

    for (let index = 0; index < items.length; index += 2) {
      processedCount++;
    }

    sendJson(res, 200, {
      status: 'ok',
      runtime: RUNTIME,
      processedCount
    });
  } catch (error) {
    if (error.message === 'REQUEST_BODY_TOO_LARGE') {
      sendJson(res, 413, {
        status: 'error',
        error: 'Request body too large'
      });

      return;
    }

    sendJson(res, 400, {
      status: 'error',
      error: 'Invalid JSON'
    });
  }
}


async function handleAuthentication(req, res) {
  try {
    const body = await readRequestBody(req, 1024 * 1024);
    const parsed = body ? JSON.parse(body) : {};

    const password =
      typeof parsed.password === 'string'
        ? parsed.password
        : TEST_PASSWORD;

    const hash =
      typeof parsed.hash === 'string'
        ? parsed.hash
        : TEST_HASH;

    const isValid = bcrypt.compareSync(password, hash);

    sendJson(res, 200, {
      status: 'ok',
      runtime: RUNTIME,
      authenticated: isValid
    });
  } catch (error) {
    sendJson(res, 400, {
      status: 'error',
      error: 'Invalid authentication body'
    });
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const host = req.headers.host || `localhost:${PORT}`;
    const url = new URL(req.url || '/', `http://${host}`);

    if (url.pathname === '/simple' && req.method === 'GET') {
      await handleSimple(req, res);
      return;
    }

    if (url.pathname === '/compute' && req.method === 'GET') {
      await handleCompute(req, res);
      return;
    }

    if (url.pathname === '/file-read' && req.method === 'GET') {
      await handleFileRead(req, res);
      return;
    }

    if (url.pathname === '/file-write' && req.method === 'POST') {
      await handleFileWrite(req, res);
      return;
    }

    if (url.pathname === '/json' && req.method === 'POST') {
      await handleJson(req, res);
      return;
    }

    if (url.pathname === '/auth' && req.method === 'POST') {
      await handleAuthentication(req, res);
      return;
    }

    sendJson(res, 404, {
      status: 'error',
      error: 'Not Found'
    });
  } catch (error) {
    console.error('[REQUEST ERROR]', error);

    if (!res.headersSent) {
      sendJson(res, 500, {
        status: 'error',
        error: 'Internal server error'
      });
    } else {
      res.end();
    }
  }
});

server.keepAliveTimeout = 5000;
server.headersTimeout = 6000;
server.requestTimeout = 30000;

server.listen(PORT, '0.0.0.0', () => {
  const initializationTime =
    performance.now() - initializationStart;

  console.log(
    `[READY] ${RUNTIME} strežnik posluša na portu ${PORT}`
  );

  console.log(
    `[APP INITIALIZATION] ${initializationTime.toFixed(2)} ms`
  );

  console.log(`[DATA DIR] ${DATA_DIR}`);
});

async function shutdown(signal) {
  console.log(`[SHUTDOWN] Prejet signal ${signal}`);

  server.close(async error => {
    if (error) {
      console.error('[SHUTDOWN ERROR]', error);
      process.exitCode = 1;
    }

    try {
      await prisma.$disconnect();
    } catch (disconnectError) {
      console.error('[PRISMA DISCONNECT ERROR]', disconnectError);
      process.exitCode = 1;
    }

    process.exit();
  });

  setTimeout(() => {
    console.error('[SHUTDOWN] Prisilna ustavitev procesa');
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));