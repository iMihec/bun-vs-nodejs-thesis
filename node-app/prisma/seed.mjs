import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

const TOTAL_USERS = 10000;
const BATCH_SIZE = 1000;

async function main() {
  await prisma.user.deleteMany();

  for (let start = 1; start <= TOTAL_USERS; start += BATCH_SIZE) {
    const end = Math.min(start + BATCH_SIZE - 1, TOTAL_USERS);
    const users = [];

    for (let id = start; id <= end; id++) {
      users.push({
        email: `user${id}@benchmark.local`,
        name: `Benchmark User ${id}`,
        role: id % 20 === 0 ? 'admin' : 'user'
      });
    }

    await prisma.user.createMany({
      data: users
    });

    console.log(`Vstavljenih uporabnikov: ${end}/${TOTAL_USERS}`);
  }

  const total = await prisma.user.count();
  const regularUsers = await prisma.user.count({
    where: {
      role: 'user'
    }
  });

  console.log(`Skupaj uporabnikov: ${total}`);
  console.log(`Uporabnikov z vlogo user: ${regularUsers}`);
}

main()
  .catch(error => {
    console.error('Napaka pri ustvarjanju baze:', error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });