# TokenBar

Claude·ChatGPT(Codex) 구독 한도와 시스템 상태를 macOS 메뉴바 2줄로 보여주는 가벼운 네이티브 앱.

```
C 18%  CPU 33%  RAM 83%     2317  ↑9.0K
G  0%  GPU 59%  DSK 51%  ✲  2298  ↓8.0K
```

클릭하면 5시간·주간 한도와 리셋 시각, 시스템 상세, 팬 제어, API 환산 비용(오늘 / 7일 / 30일)이 펼쳐짐.

## 설치

macOS 14 이상 (Apple Silicon·Intel 공용)

```bash
curl -fsSL https://raw.githubusercontent.com/llouis0622/tokenbar/main/install.sh | bash
```

- `/Applications/TokenBar.app`으로 설치되고 바로 실행됨
- 이후 업데이트는 메뉴 맨 아래 "업데이트" 버튼으로 진행
- 한도 표시에는 Claude Code(`claude` → `/login`) 또는 Codex CLI(`codex login`) 로그인이 필요. 없는 쪽은 `–` 로 표시
- 제거: `pkill -x TokenBar; rm -rf /Applications/TokenBar.app ~/Library/Application\ Support/TokenBar`

## 동작 방식

- 한도 사용률
  - `C` Claude, `G` ChatGPT·Codex의 5시간 한도 사용률. 5분마다 조회
  - CLI가 저장해 둔 로그인 토큰을 읽기만 해서 각 서비스의 사용량 API를 호출. 토큰을 갱신·저장하지 않음
  - Claude 한도는 웹·앱·CLI 사용분이 합산된 값
  - 조회에 실패하면 마지막 값을 유지하고, 토큰이 만료되면 해당 CLI를 한 번 실행하면 복구됨
- API 환산 비용
  - `~/.claude`, `~/.codex`의 CLI 로그에서 토큰 수와 모델명만 읽어 API 단가로 환산. 대화 내용은 읽지 않음
  - 메뉴를 열 때만 계산하며, 이미 읽은 파일은 추가된 부분만 다시 읽음
  - 웹·데스크톱 앱 사용분은 로컬 로그가 없어 포함되지 않음
  - 단가를 직접 지정하려면 `~/Library/Application Support/TokenBar/pricing.override.json` 작성 (USD / 100만 토큰)
- 가볍게 상주
  - 평소에는 2초 주기 시스템 측정과 5분 주기 한도 조회만 실행. 화면이 꺼지면 모두 정지
  - 드롭다운은 열 때 만들고 닫으면 해제
- 보안
  - 토큰은 `api.anthropic.com`, `chatgpt.com`으로만 전송. 허용 목록 밖 호스트와 HTTPS 이외 요청은 거부
  - 수신 포트를 열지 않고, 외부 의존성 없이 Hardened Runtime으로 서명
  - 업데이트는 이 레포의 릴리스만 받아 체크섬·번들 ID·버전·코드 서명을 확인한 뒤 교체

## 시스템 수치

| 표시 | 내용 | 갱신 |
| --- | --- | --- |
| CPU | 전체 코어 사용률 | 2초 (저전력 모드 5초) |
| GPU | GPU 사용률 | 2초 |
| RAM | 메모리 사용률 (드롭다운에 사용량 / 전체) | 2초 |
| DSK | 시스템 디스크 사용률 (드롭다운에 남은 용량) | 2초 |
| 팬 아이콘 | 팬별 현재 RPM. 고정 중이면 채워진 아이콘 | 2초 |
| ↑ ↓ | 네트워크 업로드·다운로드 속도 (초당 바이트) | 2초 |
| 온도 | CPU·GPU 온도. 드롭다운에만 표시 | 메뉴가 열려 있을 때 |

온도는 Apple Silicon 센서에서 읽으며, 칩에 따라 GPU 온도가 따로 나오지 않거나 표시되지 않을 수 있음.

## 팬 제어

- 팬마다 "자동" 또는 "고정" 선택. 고정값은 슬라이더나 숫자 입력으로 지정하며 하드웨어 최소~최대 RPM 안으로만 적용
- 처음 "제어 켜기"를 누를 때 관리자 암호를 한 번 입력. 팬 속도만 바꾸는 작은 root 헬퍼(`/Library/PrivilegedHelperTools/io.github.llouis0622.tokenbar.fan`)와 그 헬퍼만 암호 없이 실행하게 하는 sudoers 규칙(`/etc/sudoers.d/tokenbar-fan`)이 설치됨
- 헬퍼가 받는 명령은 `auto`, `set <팬> <RPM>` 두 가지뿐
- 고정 중 CPU 온도가 90°C를 넘으면 자동 모드로 복귀. 앱을 "종료" 버튼으로 끌 때도 자동으로 복귀하고, 잠자기에서 깨어나면 고정값을 다시 적용
- "제어 끄기"를 누르면 헬퍼와 규칙을 모두 삭제
- Apple Silicon 전용. 팬이 없는 모델에서는 표시되지 않음

## 라이선스

[MIT](LICENSE)
