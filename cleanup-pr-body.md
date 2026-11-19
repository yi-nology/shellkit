## 清理临时工装

另一条会话把 `tmp/ci-helper` 当普通功能分支提了 PR #154 并合进了 main
⇒ 临时工装留在了 main 里：

- `.github/workflows/tmp-ci-helper.yml` —— 会推分支、开 PR、关单的临时 workflow
- `issue-close.md` / `pr-body.md` / `probe-openeuler.sh` —— 那套工装的附件

这个 PR 把这 4 个文件删掉；配套的清理 job 还会删掉对应的临时分支
（`tmp/ci-helper` / `tmp/ci-helper-log` / `tmp/ci-helper-probe`），
避免它们再被当成普通功能分支合进 main。
