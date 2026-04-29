#!/bin/bash

# Configuration
# 스크립트가 위치한 곳의 상위 폴더(github 디렉토리)를 BASE_DIR로 설정
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOM_DIR="$BASE_DIR/bom"
TODAY=$(date +%Y%m%d)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 시작: mj-opensource 자동 배포 스크립트${NC}"

# 1. 수정된 프로젝트 추출
MODIFIED_PROJECTS=()
cd "$BASE_DIR" || exit 1

# 수정 가능한 프로젝트 목록 (bom 제외)
TARGET_PROJECTS=("core" "spring" "spring-database" "spring-web")

for dir in "${TARGET_PROJECTS[@]}"; do
  if [ -d "$dir" ]; then
    cd "$dir" || continue
    # git status --porcelain 출력 결과가 있으면 수정된 것으로 간주
    if [ -n "$(git status --porcelain)" ]; then
      MODIFIED_PROJECTS+=("$dir")
    fi
    cd "$BASE_DIR" || exit 1
  fi
done

if [ ${#MODIFIED_PROJECTS[@]} -eq 0 ]; then
  echo -e "${YELLOW}ℹ️ 수정된 프로젝트가 없습니다. 배포를 종료합니다.${NC}"
  exit 0
fi

echo -e "${GREEN}✅ 수정된 프로젝트 목록:${NC}"
for p in "${MODIFIED_PROJECTS[@]}"; do
  echo "  - $p"
done

# --- BOM 버전 추출 및 계산 ---
BOM_POM="$BOM_DIR/pom.xml"
CURRENT_BOM_VERSION=$(grep -m 1 -oE '<version>[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+</version>' "$BOM_POM" | sed -E 's/<version>(.*)<\/version>/\1/')

if [ -z "$CURRENT_BOM_VERSION" ]; then
  echo -e "${RED}❌ BOM 프로젝트의 버전을 파싱하지 못했습니다.${NC}"
  exit 1
fi

BOM_BASE=$(echo "$CURRENT_BOM_VERSION" | cut -d'.' -f1-3)
BOM_SEQ=$(echo "$CURRENT_BOM_VERSION" | cut -d'.' -f4)
NEW_BOM_VERSION="${BOM_BASE}.$((BOM_SEQ + 1))"

echo -e "${GREEN}✅ BOM 버전 업데이트: ${CURRENT_BOM_VERSION} ➡️ ${NEW_BOM_VERSION}${NC}"

# BOM pom.xml의 자신의 버전 교체
perl -pi -e "s/<version>$CURRENT_BOM_VERSION<\/version>/<version>$NEW_BOM_VERSION<\/version>/" "$BOM_POM"

# 2~3. 각 수정된 프로젝트별 처리
for PROJECT in "${MODIFIED_PROJECTS[@]}"; do
  echo -e "\n${YELLOW}▶️ [$PROJECT] 처리 중...${NC}"
  PROJECT_DIR="$BASE_DIR/$PROJECT"
  POM_FILE="$PROJECT_DIR/pom.xml"
  
  # 프로젝트 자체 버전 추출 및 계산
  CURRENT_VERSION=$(grep -m 1 -oE '<version>[0-9]+\.[0-9]+\.[0-9]+-[0-9]{8}\.[0-9]+</version>' "$POM_FILE" | sed -E 's/<version>(.*)<\/version>/\1/')
  
  if [ -z "$CURRENT_VERSION" ]; then
    echo -e "${RED}❌ $PROJECT 의 버전을 파싱하지 못했습니다.${NC}"
    exit 1
  fi
  
  BASE_VERSION=$(echo "$CURRENT_VERSION" | cut -d'-' -f1)
  DATE_PART=$(echo "$CURRENT_VERSION" | cut -d'-' -f2 | cut -d'.' -f1)
  SEQ_PART=$(echo "$CURRENT_VERSION" | cut -d'-' -f2 | cut -d'.' -f2)
  
  if [ "$DATE_PART" == "$TODAY" ]; then
    NEW_SEQ=$((SEQ_PART + 1))
  else
    NEW_SEQ=0
  fi
  
  NEW_VERSION="${BASE_VERSION}-${TODAY}.${NEW_SEQ}"
  echo -e "  - 버전 업데이트: ${CURRENT_VERSION} ➡️ ${NEW_VERSION}"
  
  # pom.xml에서 프로젝트 자신의 버전 치환 (첫 번째 <version> 태그)
  perl -pi -e "s/<version>$CURRENT_VERSION<\/version>/<version>$NEW_VERSION<\/version>/" "$POM_FILE"
  
  # pom.xml에서 BOM 의존성 버전 치환
  perl -pi -e "s/<version>$CURRENT_BOM_VERSION<\/version>/<version>$NEW_BOM_VERSION<\/version>/g" "$POM_FILE"
  
  # BOM pom.xml 안에 선언된 해당 프로젝트의 의존성 버전 치환
  # 폴더명(예: spring-web)이 곧 artifactId 이므로 그대로 사용합니다.
  ARTIFACT_NAME="$PROJECT"
  perl -0777 -pi -e "s/(<artifactId>$ARTIFACT_NAME<\/artifactId>\s*<version>)[^<]+(<\/version>)/\${1}${NEW_VERSION}\${2}/g" "$BOM_POM"
  
  # README.md 작성 프로세스
  README_FILE="$PROJECT_DIR/README.md"
  TEMP_FILE="$PROJECT_DIR/.temp_readme.md"
  
  echo -e "  - README.md 작성을 위해 에디터를 엽니다..."
  echo "<!-- ========================================== -->" > "$TEMP_FILE"
  echo "<!-- 현재 작성 중인 프로젝트: 📦 [$PROJECT] -->" >> "$TEMP_FILE"
  echo "<!-- ========================================== -->" >> "$TEMP_FILE"
  echo "<!-- 아래에 변경 사항을 요약해서 적어주세요. 이 주석들은 자동으로 삭제됩니다. -->" >> "$TEMP_FILE"
  echo "<!-- 내용을 작성하지 않고 종료하면 README.md 업데이트가 생략됩니다. -->" >> "$TEMP_FILE"
  echo "" >> "$TEMP_FILE"
  echo "- " >> "$TEMP_FILE"
  
  # vi 에디터 실행 (표준 입력을 tty로 리다이렉션하여 vi가 정상 실행되도록 함)
  ${EDITOR:-vi} "$TEMP_FILE" < /dev/tty
  
  # 주석 제거하고 임시 파일 생성
  grep -v "^<!--" "$TEMP_FILE" > "$TEMP_FILE.clean"
  
  # 내용이 비어있지 않은지 검사 ("- "만 남았을 경우 무시)
  CLEAN_CONTENT=$(cat "$TEMP_FILE.clean" | sed 's/^- $//' | tr -d ' \n\r')
  
  if [ -n "$CLEAN_CONTENT" ]; then
    INJECT_FILE="$PROJECT_DIR/.temp_inject.md"
    echo "" > "$INJECT_FILE"
    echo "### ${NEW_VERSION} - $(date +%Y%m%d)" >> "$INJECT_FILE"
    echo "" >> "$INJECT_FILE"
    cat "$TEMP_FILE.clean" >> "$INJECT_FILE"
    
    # README.md의 '## release note' 라인 아래에 작성한 내용 삽입
    awk -v f="$INJECT_FILE" '/## release note/ {
      print $0
      while ((getline line < f) > 0)
        print line
      next
    }1' "$README_FILE" > "${README_FILE}.tmp" && mv "${README_FILE}.tmp" "$README_FILE"
    
    rm -f "$INJECT_FILE"
    echo -e "${GREEN}  - README.md에 릴리즈 노트 내용이 추가되었습니다.${NC}"
  else
    echo -e "${YELLOW}  - 입력된 내용이 없어 README.md는 변경하지 않습니다.${NC}"
  fi
  
  rm -f "$TEMP_FILE" "$TEMP_FILE.clean"
done

# 4. BOM 파일 로컬 설치 및 배포
echo -e "\n${YELLOW}▶️ BOM 로컬 설치 및 배포 진행 (mvn clean deploy)...${NC}"
cd "$BOM_DIR" || exit 1
mvn clean deploy
if [ $? -ne 0 ]; then
  echo -e "${RED}❌ BOM deploy 중 오류가 발생했습니다.${NC}"
  exit 1
fi
cd "$BASE_DIR" || exit 1

# 5. 수정된 프로젝트 배포
echo -e "\n${YELLOW}▶️ 수정된 프로젝트 배포 진행 (mvn clean deploy)...${NC}"
for PROJECT in "${MODIFIED_PROJECTS[@]}"; do
  echo -e "  - $PROJECT 배포 중..."
  cd "$BASE_DIR/$PROJECT" || exit 1
  mvn clean deploy
  if [ $? -ne 0 ]; then
    echo -e "${RED}❌ $PROJECT deploy 중 오류가 발생했습니다.${NC}"
    exit 1
  fi
done

# 7. 결과 알림
echo -e "\n${GREEN}🎉 모든 배포가 성공적으로 완료되었습니다! 🎉${NC}"
osascript -e 'display notification "mj-opensource 전체 배포가 성공적으로 완료되었습니다!" with title "배포 완료"' 2>/dev/null
