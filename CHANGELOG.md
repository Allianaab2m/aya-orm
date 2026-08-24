# Changelog

## [0.2.0](https://github.com/Allianaab2m/aya-orm/compare/aya-v0.1.0...aya-v0.2.0) (2026-08-21)


### ⚠ BREAKING CHANGES

* drop RowShape now that sqlite3 0.2.0 reports storage classes
* **sql:** narrow the public API, and split the docs into chapters
* **sql:** split Executor out of Driver, go async, and nest transactions

### Features

* **cli:** replace cairn-gen with cairn-kit ([2bc0fcf](https://github.com/Allianaab2m/aya-orm/commit/2bc0fcfeb0ac449262ec4ac0cbce9cc8309bb024))
* **ddl:** snapshot the schema, diff it, and emit SQLite DDL ([4d96d40](https://github.com/Allianaab2m/aya-orm/commit/4d96d40741936664c609bf0c65ca157d37e0d961))
* **driver:** add sqlite, postgres, and fake drivers ([5225ef4](https://github.com/Allianaab2m/aya-orm/commit/5225ef4b9720e412a5a5eeac4276c0e51e6360fd))
* drop RowShape now that sqlite3 0.2.0 reports storage classes ([970cb75](https://github.com/Allianaab2m/aya-orm/commit/970cb7556b8053e53c2e339dd87ab5ab5cb8626b))
* generate DDL and migrations with cairn-kit ([04b87e0](https://github.com/Allianaab2m/aya-orm/commit/04b87e0c6072b16d82af612acbf96de51c710578))
* **gen:** read DDL metadata from #cairn attributes ([b0f882f](https://github.com/Allianaab2m/aya-orm/commit/b0f882fecf768110bc93fdf4b860ea571911a62f))
* initial commit ([955bb2b](https://github.com/Allianaab2m/aya-orm/commit/955bb2b90db0f220e0d95561ea032af7360107d9))
* **kit:** plan a migration from the journal and two snapshots ([a9bec6e](https://github.com/Allianaab2m/aya-orm/commit/a9bec6ea5a2f5ff4e596f7d05ce70f230a0d80f9))
* **sql:** let a driver ask for a typed SELECT list ([80b0e67](https://github.com/Allianaab2m/aya-orm/commit/80b0e67cf1677c6599bf3caaa693494ec3229d4f))
* **sql:** name the shape of a chained join with map_cols and split2 ([d24ab38](https://github.com/Allianaab2m/aya-orm/commit/d24ab38ec8e730fa753dfd7539c279e1902f49f4))
* **sql:** split Executor out of Driver, go async, and nest transactions ([8fc35ae](https://github.com/Allianaab2m/aya-orm/commit/8fc35ae6caab4dd1f38dd35ca69d67f43b9a1a66))
* **sql:** summarise rows with Reducer, reduce, and group_by ([3f724f7](https://github.com/Allianaab2m/aya-orm/commit/3f724f7e71efb067f84b6a514ff2433756500510))


### Code Refactoring

* **sql:** narrow the public API, and split the docs into chapters ([c949098](https://github.com/Allianaab2m/aya-orm/commit/c949098123d445530bfe84a10d67538ddbdd3545))
