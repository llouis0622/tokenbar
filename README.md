# TokenBar

Claude·ChatGPT(Codex) 구독 한도 사용률과 시스템 상태를 macOS 메뉴바 2줄에 띄워주는 작은 네이티브 앱.

```
C 18%  CPU 33%  RAM 83%  ↑9.0K
G  0%  GPU 59%  DSK 51%  ↓8.0K
```

- `C` Claude 5시간 한도 사용률, `G` ChatGPT·Codex 5시간 한도 사용률
- CPU·GPU 사용률, 메모리·디스크 사용률, 네트워크 업·다운 속도 (2초마다 갱신)
- 클릭하면 5시간·주간 한도 바, 리셋까지 남은 시간, 시스템 상세(온도·메모리 용량·디스크 여유), API 환산 비용(오늘 / 7일 / 30일)

## 무엇을 보여주나

| 항목 | 출처 | 웹·앱 사용분 포함 |
| --- | --- | --- |
| Claude 한도 % | `api.anthropic.com/api/oauth/usage` (Claude Code OAuth 토큰) | 포함 (구독 한도는 웹·앱·CLI 합산) |
| ChatGPT·Codex 한도 % | `chatgpt.com/backend-api/wham/usage` (`~/.codex/auth.json` 토큰) | Codex 한도 기준 |
| API 환산 비용 | `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl` | 미포함 (CLI 로컬 로그만) |

- 웹·데스크톱 앱 대화는 로컬에 토큰 로그를 남기지 않아 토큰 수·비용으로는 집계할 수 없음. 대신 구독 한도 %가 전체 사용량을 반영.
- 두 한도 API는 공식 문서화된 엔드포인트가 아니라서 응답 형식이 바뀌면 표시가 멈출 수 있음. 이 경우 마지막 값(캐시)과 Codex 로컬 로그의 `rate_limits` 값으로 대체 표시.

## 설치

요구 사항: macOS 14 이상, Xcode Command Line Tools (`xcode-select --install`)

```bash
git clone https://github.com/llouis0622/tokenbar.git
cd tokenbar
./build-app.sh --install
```

`/Applications/TokenBar.app`으로 설치되고 바로 실행됨. Dock 아이콘 없이 메뉴바에만 표시.

## 업데이트

- 메뉴를 열면 맨 아래에 현재 버전과 "업데이트" 버튼이 표시됨. 터미널 작업 불필요
- 버튼을 누르면 설치할 때 쓴 소스 폴더에서 `git pull --ff-only` → 재빌드 → 재설치 → 자동 재시작 (약 1분)
- 새 변경이 있는지는 실행 직후와 6시간마다 `git fetch`로 확인
- 소스 폴더를 옮기거나 지웠다면 다시 `./build-app.sh --install` 한 번 실행
- 실패하면 `~/Library/Application Support/TokenBar/update.log` 확인
- 터미널에서 직접 하려면 `./build-app.sh --update`

## 사전 조건

- Claude: 터미널에서 `claude` 실행 후 `/login` 된 상태
- Codex: `codex login` 으로 ChatGPT 계정 로그인 된 상태 (API 키 로그인은 구독 한도가 없음)

둘 중 하나만 써도 동작하며, 없는 쪽은 `–` 로 표시.

## 가볍게 유지하는 방식

- 상태바는 AppKit `NSStatusItem`에 직접 그림. 드롭다운(SwiftUI)은 열 때 만들고 닫으면 해제
- 평소에 도는 작업은 두 가지뿐
  - 시스템 수치 측정: 2초마다 (저전력 모드 5초), 타이머 허용 오차를 둬서 다른 작업과 묶여 깨어남. 표시 문자열이 바뀔 때만 다시 그림
  - 한도 조회: 5분마다 HTTPS 요청 2건
- 화면이 꺼지면 두 타이머 모두 정지, 켜지면 재개
- 비용 계산(로그 스캔)은 메뉴를 열 때만 실행
  - 파일별로 읽은 위치를 기억해 추가된 줄만 파싱, 1MB 단위로 끊어 읽음
  - 기록은 메시지당 40바이트 정도의 숫자 구조체로만 보관
- 온도 센서는 메뉴가 열려 있을 때만 읽음
- 디스크에 쓰는 것: `limits.json`, `prices.json`, 업데이트 시 `update.log`. HTTP 캐시·쿠키 없음

## 보안

- 토큰 취급
  - Claude Code·Codex CLI가 이미 저장해 둔 OAuth 토큰을 읽기만 함. 갱신·재발급·파일 저장·로그 출력 없음
  - Claude 토큰은 `/usr/bin/security`로 키체인에서 읽고 만료 전까지 메모리에만 보관
  - 토큰은 `api.anthropic.com`, `chatgpt.com` 두 곳으로만 전송
- 네트워크
  - 허용 목록(`api.anthropic.com`, `chatgpt.com`, `raw.githubusercontent.com`) 이외 호스트와 HTTPS 이외 스킴은 요청 자체를 거부
  - 리다이렉트를 따라가지 않음 (토큰이 다른 호스트로 넘어가는 경로 차단)
  - TLS 1.2 이상, 임시 세션(쿠키·캐시·자격 증명 저장소 없음), 응답 크기 16MB 상한
  - 수신 포트를 열지 않음. 외부에서 이 앱으로 접속할 수 있는 경로 없음
- 로컬 데이터
  - 로그에서 토큰 숫자·모델명·시각만 읽음. 대화 내용은 읽거나 저장하지 않음
  - 데이터 폴더 권한 700, 파일 권한 600
- 실행 파일
  - Hardened Runtime으로 서명 (라이브러리 주입·디버거 연결 차단), 외부 의존성 0
  - 외부 프로세스는 절대 경로(`/usr/bin/security`, `/usr/bin/git`, `/bin/bash`)와 인자 배열로만 실행. 셸 문자열 조합 없음
- 업데이트
  - 소스 폴더의 `origin`이 `github.com/llouis0622/tokenbar`일 때만 진행, `--ff-only`로만 병합
  - 받은 코드를 그대로 빌드해 실행하므로 신뢰 범위는 이 GitHub 레포에 푸시할 수 있는 계정과 같음. 계정 2단계 인증 권장
- 한계
  - App Sandbox 미적용 (`~/.claude`, `~/.codex`, 키체인 읽기에 필요)
  - 애드혹 서명이라 Apple 공증은 없음. 직접 빌드한 바이너리만 실행하는 전제
  - 같은 사용자 계정으로 실행되는 다른 프로그램은 이 앱과 무관하게 CLI 토큰 파일·키체인 항목에 접근할 수 있음. 이 앱이 그 범위를 넓히지는 않음

## 동작 방식

- 제공자별 한도 API 호출은 최소 60초 간격. HTTP 429 응답 시 `Retry-After` 또는 최소 5분 대기 후 재시도, 그동안 마지막 값 유지
- 토큰이 만료되면 해당 CLI를 한 번 실행하면 갱신됨

## 시스템 수치

- CPU·메모리: Mach `host_statistics`, GPU: IOKit `IOAccelerator`의 `Device Utilization %`, 디스크: 시스템 볼륨 여유 공간, 네트워크: `en*` 인터페이스 바이트 카운터 차이
- 온도는 드롭다운을 열었을 때만 측정. Apple Silicon의 비공개 HID 센서 API를 쓰므로 macOS 업데이트로 읽지 못하게 되면 온도 칸만 비워짐
  - M1 계열은 CPU·GPU 온도를 따로 표시, 센서 이름이 `PMU tdie`로만 나오는 칩은 CPU 온도(다이 평균)만 표시

## 비용 계산

- 단가는 [LiteLLM 가격표](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)를 하루 한 번 받아 사용
- 가격표에 없는 모델은 계열별 기본 단가(`Sources/TokenBarCore/Pricing.swift`의 `families`)로 근사
- 직접 지정하려면 `~/Library/Application Support/TokenBar/pricing.override.json` 작성 (USD / 100만 토큰)

```json
{
  "claude-opus-4-5": { "input": 5, "output": 25, "cacheWrite5m": 6.25, "cacheWrite1h": 10, "cacheRead": 0.5 }
}
```

- 구독 사용자는 이 금액을 실제로 내지 않음. "API로 썼다면 얼마였을지"의 참고 수치

## 구조

```
Sources/TokenBarCore   한도 조회, 로그 스캔, 단가, 시스템 측정, 업데이트, 포맷
Sources/CSensors       온도 센서 읽기 (C)
Sources/TokenBar       NSStatusItem 2줄 렌더링, 드롭다운(SwiftUI)
Resources              Info.plist, 앱 아이콘
Tests/TokenBarCoreTests
build-app.sh           릴리스 빌드 → TokenBar.app 패키징 (--install, --update)
```

로컬 데이터: `~/Library/Application Support/TokenBar/` (`limits.json`, `prices.json`, `update.log`)

## 개발

```bash
swift test
swift run TokenBar
```

## 제거

```bash
pkill -x TokenBar
rm -rf /Applications/TokenBar.app ~/Library/Application\ Support/TokenBar
```

## 참고한 프로젝트

- [seoyeon1123/tokenplant](https://github.com/seoyeon1123/tokenplant)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)
- [grzegorz-raczek-unit8/claude-quota](https://github.com/grzegorz-raczek-unit8/claude-quota)
