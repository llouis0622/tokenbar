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

처음 실행하면 `security`가 `Claude Code-credentials` 키체인 항목에 접근한다는 팝업이 뜸. "항상 허용"을 누르면 이후 다시 묻지 않음.

## 사전 조건

- Claude: 터미널에서 `claude` 실행 후 `/login` 된 상태
- Codex: `codex login` 으로 ChatGPT 계정 로그인 된 상태 (API 키 로그인은 구독 한도가 없음)

둘 중 하나만 써도 동작하며, 없는 쪽은 `–` 로 표시.

## 동작 방식

- 5분마다 자동 갱신, 메뉴를 열 때도 갱신 (제공자별 API 호출은 최소 60초 간격)
- HTTP 429 응답 시 `Retry-After` 또는 최소 5분 대기 후 재시도, 그동안 마지막 값 유지
- OAuth 토큰은 읽기만 함. 갱신·저장·재발급하지 않으므로 CLI 로그인 상태에 영향 없음
  - 토큰이 만료되면 해당 CLI를 한 번 실행하면 갱신됨
- 로컬 로그는 `message.usage`의 토큰 숫자와 모델명만 읽음. 대화 내용은 읽지 않음
- 로그 파일은 크기·수정 시각이 바뀐 것만 다시 파싱

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
Sources/TokenBarCore   한도 조회, 로그 스캔, 단가, 시스템 측정, 포맷
Sources/CSensors       온도 센서 읽기 (C)
Sources/TokenBar       SwiftUI MenuBarExtra UI, 메뉴바 2줄 이미지 렌더링
Tests/TokenBarCoreTests
build-app.sh           릴리스 빌드 → TokenBar.app 패키징 (--install 옵션)
```

로컬 데이터: `~/Library/Application Support/TokenBar/` (`limits.json`, `prices.json`)

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
