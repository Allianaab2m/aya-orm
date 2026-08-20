CREATE TABLE "orders" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "items" INTEGER NOT NULL,
  "status" TEXT NOT NULL,
  "submitted_at" TEXT,
  "tracking" TEXT
);
--> statement-breakpoint
CREATE TABLE "users" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "name" TEXT NOT NULL,
  "age" INTEGER NOT NULL,
  "deleted_at" TEXT
);
