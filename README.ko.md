<p align="center">
  <img src="docs/icon-1024.png" width="128" alt="ConfigDeck 아이콘" />
</p>

# ConfigDeck

[![CI](https://github.com/sanghun0724/configdeck/actions/workflows/ci.yml/badge.svg)](https://github.com/sanghun0724/configdeck/actions/workflows/ci.yml)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/sh_brady)

[English](README.md) | **한국어**

여기저기 흩어진 `~/.claude` 설정을 **한눈에** 보여주는 네이티브 macOS(SwiftUI)
앱입니다. Skills, agents, settings, hooks, MCP 서버, 슬래시 커맨드 —
전부 하나의 구조화된, 검색 가능한 창에서 확인하세요.

> *"내가 대체 뭘 설정해놨더라?"* 를 수십 개 파일에서 쉽게 확인할 수 없는
> Claude Code 사용자를 위해 만들었습니다. 읽기 우선 설계: 둘러보는 동안에는
> 파일을 절대 건드리지 않고, 모든 편집은 백업을 먼저 뜬 뒤 명시적인 Save를
> 거쳐야만 저장됩니다.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
    <img src="docs/screenshot-light.png" width="820" alt="ConfigDeck — Skills 섹션과 상세 뷰" />
  </picture>
</p>

## 왜 만들었나

Claude Code 설정은 수많은 파일과 디렉토리(`skills/`, `agents/`,
`settings.json`, `~/.claude.json`, `commands/`, …)에 흩어져 있습니다.
파일 하나를 편집하기는 쉽지만, *전체 그림을 보기*는 어렵습니다.
이 대시보드는 지금까지 설정해둔 모든 것을 한곳에서 조망하게 해줍니다.

## 기능 (v1)

<p align="center">
  <img src="docs/demo.gif" width="820" alt="데모 — 검색으로 스킬 필터링, 마크다운 에디터 열기, Agents·Hooks·Settings 둘러보기" />
</p>
<p align="center"><sub>스킬 검색 → frontmatter 하이라이팅 마크다운 에디터 → Agents · Hooks · Settings</sub></p>

| 섹션 | 표시 내용 | 편집 |
|------|-----------|------|
| **Skills** | 이름, 설명, 레벨, argument hint | 마크다운 에디터 + 새로 만들기 |
| **Agents** | 모델·툴 제한 | 마크다운 에디터 + 새로 만들기 |
| **Commands** | 슬래시 커맨드 (파일 + 네임스페이스 폴더) | 마크다운 에디터 + 새로 만들기 |
| **MCP Servers** | `~/.claude.json`의 서버 목록 | 추가 / 삭제 / 편집 (command, args, url) |
| **Hooks** | `settings.json`의 이벤트, matcher, 커맨드 | 추가 / 삭제 |
| **Settings** | 권한 규칙 (allow / ask / deny) + 환경변수 | 인라인 편집 |

- 모든 섹션에서 검색/필터 (`⌘K`로 검색 필드 포커스)
- 심볼릭 링크 추적 (예: `~/.claude/skills` → 외부 설정 repo)
- 파일 외부 변경 감지 — 보고 있는 동안 Claude Code가 `~/.claude.json`을
  다시 쓰면 앱이 자동으로 리로드합니다 (저장 안 한 편집이 있으면 덮어쓰는
  대신 경고)
- UI 언어: 시스템 / English / 한국어 / Español / 中文 / 日本語
  (Settings → Language, 적용하려면 재시작 필요)

## 안전 모델

이 앱은 **읽기 우선**입니다: 명시적으로 Save를 누르기 전까지 아무것도
쓰지 않습니다. 모든 쓰기는 동일한 보호 경로를 거칩니다:

1. **백업 먼저** — 디스크의 기존 버전을 `~/.claude/backups`에 복사
   (파일당 최근 20개 보관, Restore로 아무 버전이나 복원 가능).
2. **Stale-guard** — 로드한 뒤 디스크에서 파일이 바뀌었다면, 다른 곳의
   변경을 덮어쓰는 대신 저장을 거부합니다.
3. **원자적 쓰기** — 새 내용이 한 번에 파일을 교체합니다. 크래시가 나도
   반쯤 쓰인 설정 파일이 남지 않습니다.
4. **모르는 키 보존** — 앱이 모델링하지 않는 JSON 키와 서버별 필드
   (env, headers, projects, history, …)는 저장 후에도 그대로 유지됩니다.

전체 write-back 설계는 [`DESIGN-writeback.md`](DESIGN-writeback.md)를 참고하세요.

앱은 `~/.claude`와 `~/.claude.json`을 읽기 위해 **샌드박스 없이** 실행됩니다 —
사용자 권한으로 실행하는 다른 프로세스와 동일한 파일시스템 접근 권한을
가진다는 뜻입니다. 직접 컴파일하지 않은 빌드를 실행하기 전에는 소스를
확인하세요.

## 설치

### 빠른 설치 (Gatekeeper 팝업 없음)

```sh
curl -fsSL https://raw.githubusercontent.com/sanghun0724/configdeck/main/install.sh | sh
```

최신 릴리즈를 받아 `/Applications`에 설치합니다. 앱이 아직
공증(notarize)되지 않았지만 ([팝업이 뜨는 이유](#not-notarized)) —
curl 다운로드에는 격리 플래그가 붙지 않아 이 경로는 팝업을 완전히
건너뜁니다. 걱정되면 [스크립트](install.sh)를 먼저 읽어보세요. 50줄 정도입니다.

### Homebrew

```sh
brew install --cask sanghun0724/tap/configdeck
xattr -cr /Applications/ConfigDeck.app   # Gatekeeper 격리 플래그 제거
```

### 다운로드

[Releases](https://github.com/sanghun0724/configdeck/releases)에서 최신
`.zip`을 받아 압축을 풀고 `ConfigDeck.app`을 Applications로 드래그하세요.

<a name="not-notarized"></a>
Homebrew·브라우저 다운로드에는 격리 플래그가 붙고 ConfigDeck은 아직
공증되지 않았기 때문에, 첫 실행 시 macOS가 차단합니다.
`xattr -cr /Applications/ConfigDeck.app`을 실행하거나,
**시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 누르세요
(macOS 14에서는 앱 우클릭 → **열기** → **열기**도 가능).

### 소스 빌드

macOS 14+, Xcode 15+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen) 필요:

```sh
brew install xcodegen
xcodegen generate
open ConfigDeck.xcodeproj
# ⌘R로 실행, 또는:
xcodebuild -scheme ConfigDeck -configuration Debug build
```

앱은 홈 디렉토리의 `~/.claude`와 `~/.claude.json`을 읽습니다.
아직 Claude Code를 사용하지 않는다면 섹션이 비어 있습니다 —
`settings.json`과 `~/.claude.json`은 첫 저장 시 생성됩니다.

## 로드맵

- ✅ 모든 섹션의 안전한 편집 (permissions, env, hooks, MCP, 마크다운 파일)
- ✅ 전역 검색, 파일 감지, 백업 선택기, 새로 만들기 스캐폴드
- skills/agents용 구조화된 frontmatter 폼 (현재는 raw 마크다운)
- 팀원 간 스킬 공유 / 탐색
- 라이브 세션 & 캐시 조회

## 기여하기

작은 프로젝트, 간단한 규칙 — [CONTRIBUTING.md](CONTRIBUTING.md)를 보세요.

## 후원

ConfigDeck이 유용했다면 커피 한 잔 사주세요!

<a href="https://buymeacoffee.com/sh_brady" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" width="200"></a>

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
