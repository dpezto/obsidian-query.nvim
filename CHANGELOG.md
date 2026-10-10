# Changelog

## [0.1.2](https://github.com/dpezto/obsidian-query.nvim/compare/v0.1.1...v0.1.2) (2026-10-10)


### Bug Fixes

* **cache:** release query results no buffer references ([7a7073f](https://github.com/dpezto/obsidian-query.nvim/commit/7a7073febd54263f0e057eb125b4acd071f32164))
* correctness and performance fixes ([9888480](https://github.com/dpezto/obsidian-query.nvim/commit/988848014ab917cc6b034619fdb01fa88ddd0fd0))
* **dataview:** build day values from calendar dates ([2b097a9](https://github.com/dpezto/obsidian-query.nvim/commit/2b097a997a21d967855c92ccde3a1cba1f602292))
* **dataview:** emit no rows when flattening an empty array ([fe5701c](https://github.com/dpezto/obsidian-query.nvim/commit/fe5701caa3fd90edfd74bf17fee61fe8ebe58911))
* **dataview:** group GROUP BY rows by value equality ([f97038e](https://github.com/dpezto/obsidian-query.nvim/commit/f97038ecaff31e599831e951a0fb980192f4b3a8))
* **dataview:** keep false values and honor WITHOUT ID in projections ([9653e6d](https://github.com/dpezto/obsidian-query.nvim/commit/9653e6d1f80dcf28c34a7fa27df58ae502cb130d))
* **dataview:** refresh heat highlights only on background changes ([f815f76](https://github.com/dpezto/obsidian-query.nvim/commit/f815f76a3de72aadb9031f769c91e451e4906868))
* **index:** ignore tilde code fences when extracting note data ([c98dd63](https://github.com/dpezto/obsidian-query.nvim/commit/c98dd63bf6e09c894db6e2bb890fbfb2db96b0bb))
* **index:** read file stats from the nested cache row layout ([e3998ef](https://github.com/dpezto/obsidian-query.nvim/commit/e3998ef3c4b02209cf147d05d527b5ada5462157))
* **index:** resolve relative Markdown links from the linking note ([44fa394](https://github.com/dpezto/obsidian-query.nvim/commit/44fa394b6f4e8062d26ecb9d3811c384e7e4acf5))
* **inline:** refresh inline values after concurrent and external changes ([c3271fb](https://github.com/dpezto/obsidian-query.nvim/commit/c3271fb6e3646459492663df0cd1d454ecd07050))
* **regex:** keep translated groups non-capturing ([7f4f3b5](https://github.com/dpezto/obsidian-query.nvim/commit/7f4f3b5aa9fbb8b24335f23e4da8c5ceedaa4508))
* **search:** keep filename matching inside boolean expressions ([34a5b1b](https://github.com/dpezto/obsidian-query.nvim/commit/34a5b1b33670ea508c5f5a1e2a1a1646fdcc6654))
* **search:** keep non-ASCII characters in inline tags ([37c89b4](https://github.com/dpezto/obsidian-query.nvim/commit/37c89b4c98c9004fb2f671ccd252b0abe6073855))
* **search:** lex regex arguments attached to operators ([c1c7e41](https://github.com/dpezto/obsidian-query.nvim/commit/c1c7e41f1e61bf89b1cdc6d577f02ff747214d03))
* **workspace:** query non-strict workspaces from the vault root ([ea469fd](https://github.com/dpezto/obsidian-query.nvim/commit/ea469fde8d9838c694e24c48a144265691b7a4d0))
* **workspace:** retry requests stranded by a workspace switch ([49f565f](https://github.com/dpezto/obsidian-query.nvim/commit/49f565fc2ac4eee53e535aee661935c6dcaae063))


### Performance Improvements

* **blink:** cache vault completion data between changes ([6bdce0a](https://github.com/dpezto/obsidian-query.nvim/commit/6bdce0a7f88ce2f4ddb06e2780946c25c03c3334))
* **cache:** stop rerunning every query on buffer entry ([a839142](https://github.com/dpezto/obsidian-query.nvim/commit/a839142274466fe5dca666d1917df9b6e6d4ae82))
* **dataview:** hash values in unique() ([02e204c](https://github.com/dpezto/obsidian-query.nvim/commit/02e204c8b0e93298940be9deb3963fba7f0103eb))
* **index:** skip supplements another request already refreshed ([69931cd](https://github.com/dpezto/obsidian-query.nvim/commit/69931cdb9ddeb7e3fea43e52d01210b93121abc2))

## [0.1.1](https://github.com/dpezto/obsidian-query.nvim/compare/v0.1.0...v0.1.1) (2026-09-14)


### Bug Fixes

* **dataview:** synchronize task completion and query refresh ([8cc85eb](https://github.com/dpezto/obsidian-query.nvim/commit/8cc85ebff909e621d2d4f80776c61ae36dcd399f))
* **dataview:** synchronize task completion and query refresh ([c62a041](https://github.com/dpezto/obsidian-query.nvim/commit/c62a0415e659161287eae5e655e9003cc50f0bf4))
* refresh query results reliably right after a note is saved ([1b07ed0](https://github.com/dpezto/obsidian-query.nvim/commit/1b07ed045944c35b60420f0682b42c352319d9f9))
* refresh query results reliably right after a note is saved ([9f86c46](https://github.com/dpezto/obsidian-query.nvim/commit/9f86c46f43f9e7ee99392720b28e2497cf8a3c20))
* **render:** mirror render-markdown checkbox config for task states ([00dcffa](https://github.com/dpezto/obsidian-query.nvim/commit/00dcffae05f2eb20acddca63b76bf3632d1041ec))
* **render:** mirror render-markdown checkbox config for task states ([dba134b](https://github.com/dpezto/obsidian-query.nvim/commit/dba134b9626aed8b754f32620d5fab876675c93d))

## 0.1.0 (2026-07-30)


### Features

* calendar durations, real regex, csv() source, starred, formats ([ceea56a](https://github.com/dpezto/obsidian-query.nvim/commit/ceea56ab71727335f963586889ab5b1ffba28488))
* **calendar:** count heat map with legend; cleanup ([48cb10d](https://github.com/dpezto/obsidian-query.nvim/commit/48cb10d12975b74f7e337060ca81b2c50b96f796))
* **calendar:** one month at a time with navigation ([d6ea0d0](https://github.com/dpezto/obsidian-query.nvim/commit/d6ea0d0c43469bb1fa4c3a0b40fc9057addb4f5d))
* CI, vimdoc, file.lists, task toggling, multi-vault fixes ([3fb555b](https://github.com/dpezto/obsidian-query.nvim/commit/3fb555b1e0a695ae9477504dc61f8e7ddc03b0d2))
* initial extraction from nvim config ([5c2b7bc](https://github.com/dpezto/obsidian-query.nvim/commit/5c2b7bc63c0e2edaefc756da63d3ea75027735b8))
* picker backends, icon fallbacks, saner defaults ([d724a1e](https://github.com/dpezto/obsidian-query.nvim/commit/d724a1ef2371bbd25742178f9a0f77ada65eeeb4))
* picker backends, icon fallbacks, saner defaults ([47e345f](https://github.com/dpezto/obsidian-query.nvim/commit/47e345f0d4cca7df39ed53b0e9552a30e287c278))
* **render:** nerd-font key glyphs in result hints ([19227df](https://github.com/dpezto/obsidian-query.nvim/commit/19227dfb04a1a58c20492777c67c61fe76c03537))
* short picker titles, attachment-aware search ([d42eea6](https://github.com/dpezto/obsidian-query.nvim/commit/d42eea6bee10f3525013980b9b87030198bb53c7))


### Bug Fixes

* derive workspace from buffer path, survive workspace switches ([183dafd](https://github.com/dpezto/obsidian-query.nvim/commit/183dafd7acaec0ca0ad483acec6738d9446ddba3))
* **dql:** false results survived as NULL; negative durations ([980da39](https://github.com/dpezto/obsidian-query.nvim/commit/980da3975a438dee50c7566c0bef34e7e9012774))


### Miscellaneous Chores

* bootstrap releases at 0.1.0 ([4703e83](https://github.com/dpezto/obsidian-query.nvim/commit/4703e832179942021a20a184573f36aa2277fa18))
