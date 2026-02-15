# [](https://github.com/czprz/transmission-wireguard/compare/v0.6.0...v) (2026-02-15)


### Features

* add release notes generation and ignore RELEASE_BODY.md ([e9abdb0](https://github.com/czprz/transmission-wireguard/commit/e9abdb0f36f1c0af8fb0d4de785b8056f03864e5))



# [0.6.0](https://github.com/czprz/transmission-wireguard/compare/v0.5.1...v0.6.0) (2026-02-15)


### Features

* enhance release notes generation using conventional-changelog ([86d41a7](https://github.com/czprz/transmission-wireguard/commit/86d41a723d57b3880fe10adc0cf1e72698fc20e7))



## [0.5.1](https://github.com/czprz/transmission-wireguard/compare/v0.5.0...v0.5.1) (2026-02-15)


### Bug Fixes

* update release notes header to include only the date ([e372530](https://github.com/czprz/transmission-wireguard/commit/e37253097138c537d2b2466c75a5826ded43e91d))



# [0.5.0](https://github.com/czprz/transmission-wireguard/compare/v0.4.0...v0.5.0) (2026-02-15)


### Features

* improve release notes generation by including version and commit log ([84717b2](https://github.com/czprz/transmission-wireguard/commit/84717b2a94ac5d61f0fdab610ac91ddaaab1d888))



# [0.4.0](https://github.com/czprz/transmission-wireguard/compare/v0.3.3...v0.4.0) (2026-02-15)


### Features

* enhance release notes generation in Helm workflow ([3af4bb0](https://github.com/czprz/transmission-wireguard/commit/3af4bb0ebcd281919518a174c4f9252319635e82))



## [0.3.3](https://github.com/czprz/transmission-wireguard/compare/v0.3.2...v0.3.3) (2026-02-15)


### Bug Fixes

* remove RELEASE_NOTES.md as it is no longer needed ([ef0ae32](https://github.com/czprz/transmission-wireguard/commit/ef0ae32389ee08b19eb29d6575fa6e72da2cccdc))



## [0.3.2](https://github.com/czprz/transmission-wireguard/compare/v0.3.1...v0.3.2) (2026-02-15)


### Bug Fixes

* remove generation of RELEASE_NOTES.md from Helm workflow ([c8bf775](https://github.com/czprz/transmission-wireguard/commit/c8bf7753857abac287951e0c41241c3c00847222))



## [0.3.1](https://github.com/czprz/transmission-wireguard/compare/v0.3.0...v0.3.1) (2026-02-15)


### Bug Fixes

* enable persistence configuration for PVC in values.yaml ([bf98de3](https://github.com/czprz/transmission-wireguard/commit/bf98de346dfbe955d670c015df8c4552d3bcd32f))
* enforce required persistence.size for PVC in values.yaml and update storage request in pvc.yaml ([ec0bdb2](https://github.com/czprz/transmission-wireguard/commit/ec0bdb290e183ea384ecb82f200ca86d7fec7433))



# [0.3.0](https://github.com/czprz/transmission-wireguard/compare/v0.2.0...v0.3.0) (2026-02-15)


### Bug Fixes

* add missing targetPort fields for service ports in tests ([02df300](https://github.com/czprz/transmission-wireguard/commit/02df300d18efbf5137fed2bd71c0cca78d1951ef))
* add user and group ID to Helm unittest Docker run command for consistency ([6e0e6a4](https://github.com/czprz/transmission-wireguard/commit/6e0e6a47fc2a1d31cf2c950bcc5c42574c61a42d))
* downgrade kubeconform version to v1.0.0 in workflow files ([f2c0e52](https://github.com/czprz/transmission-wireguard/commit/f2c0e52a20c11b6f6261444c3d6416b2d298efa2))
* format indentation in Chart.yaml for consistency ([19dae92](https://github.com/czprz/transmission-wireguard/commit/19dae92b5753b5f2c59d4959dfd0050834f3ac38))
* replace helm-unittest plugin installation with action usage in workflows ([4138cdb](https://github.com/czprz/transmission-wireguard/commit/4138cdbb7e5592c0433b91ea7b309ecceb88ee50))
* update Helm unittest action to use Docker run command for consistency ([05a4600](https://github.com/czprz/transmission-wireguard/commit/05a46008f67e803491a996a7d0ffc69d1e8a5c45))
* update kubeconform setup to use version 0.6.7 in workflow files ([948d10c](https://github.com/czprz/transmission-wireguard/commit/948d10cd9824192c44de4d37dec9ac67326f9097))
* update PVC template to use default values for accessModes and storage size ([66bda83](https://github.com/czprz/transmission-wireguard/commit/66bda837de2a5c9b4d4cc9118789634dfee4257d))


### Features

* add chart-testing setup and tests for deployment and service ([f1bae29](https://github.com/czprz/transmission-wireguard/commit/f1bae2995756303c8d7950cb48fb5941a042114d))



# [0.2.0](https://github.com/czprz/transmission-wireguard/compare/v0.1.3...v0.2.0) (2026-02-15)


### Features

* add trigger for Helm Release workflow on version bump and enable manual dispatch ([a06d6e0](https://github.com/czprz/transmission-wireguard/commit/a06d6e0825f2f2d6ac6970897d9b02050aa2d2a8))



## [0.1.3](https://github.com/czprz/transmission-wireguard/compare/v0.1.2...v0.1.3) (2026-02-15)



## [0.1.2](https://github.com/czprz/transmission-wireguard/compare/v0.1.1...v0.1.2) (2026-02-15)



## 0.1.1 (2026-02-15)



