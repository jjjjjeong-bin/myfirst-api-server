// ============================================================
// Jenkinsfile-CI-buildah (agent any 버전)
// k8s 배포 Jenkins 전용 CI 파이프라인
// ※ ArgoCD GitOps 방식으로 배포 (Jenkins는 gitops 브랜치만 업데이트)
//
// [Jenkinsfile-CICD-buildah 대비 차이점]
//   - Update K8s Manifests + Deploy to Kubernetes 대신 → GitOps Update
//   - gitops 브랜치 push → ArgoCD가 자동 배포 수행
//
// [Stage 흐름]
//   1. Clone Repository            : GitHub에서 소스 코드 클론
//   2. Build with Maven            : Maven으로 JAR 빌드
//   3. Image Build & Push (Buildah): Buildah로 컨테이너 이미지 빌드 후 Harbor에 푸시
//   4. GitOps Update               : kustomize/overlays/dev 이미지 태그 수정 후 gitops 브랜치에 강제 푸시 → ArgoCD 트리거
// ============================================================
pipeline {
  agent any

  environment {
    // === 사용자 수정 영역 ===
    GIT_URL                = 'https://{{GIT_REPO_URL}}'
    GIT_BRANCH             = '{{GIT_BRANCH}}'
    GIT_ID                 = 'skala-github-id'
    IMAGE_NAME             = '{{USER_NAME}}-{{IMAGE_NAME}}'
    // =======================
    IMAGE_TAG              = '1.0'
    IMAGE_REGISTRY_URL     = '{{DOCKER_REGISTRY}}'
    IMAGE_REGISTRY_PROJECT = '{{PROJECT_NAME}}'
    DOCKER_CREDENTIAL_ID   = 'skala-image-registry-id'
    GITOPS_BRANCH          = 'gitops'
    GITOPS_MANIFEST_DIR    = 'kustomize/overlays/dev'
  }

  options {
    disableConcurrentBuilds()
    timestamps()
  }

  stages {
    stage('Clone Repository') {
      steps {
        echo 'Clone Repository'
        git branch: "${GIT_BRANCH}", url: "${GIT_URL}", credentialsId: "${GIT_ID}"
        script {
          // 이미지 태그 = IMAGE_TAG-빌드번호-커밋해시(7자리), 이후 스테이지(이미지 빌드/GitOps)에서 동일 값 사용
          // ※ kaniko/buildkit 등 빌드 컨테이너에는 git이 없을 수 있으므로 클론 직후 여기서 계산
          def shortCommit = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
          env.FINAL_IMAGE_TAG = "${env.IMAGE_TAG}-${env.BUILD_NUMBER}-${shortCommit}"
        }
        sh 'ls -al'
      }
    }

    stage('Build with Maven') {
      steps {
        echo 'Build with Maven'
        sh 'mvn clean package -DskipTests'
        sh 'ls -al'
      }
    }

    // 로그인/빌드/푸시/정리
    // --isolation chroot : user namespace 미사용 (k8s 환경에서 권한 문제 우회)
    stage('Image Build & Push (Buildah)') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: "${DOCKER_CREDENTIAL_ID}",
          usernameVariable: 'REG_USER',
          passwordVariable: 'REG_PASS'
        )]) {
          sh '''
            set -eux
            REG_HOST="${IMAGE_REGISTRY_URL}"
            IMAGE_REF="${IMAGE_REGISTRY_URL}/${IMAGE_REGISTRY_PROJECT}/${IMAGE_NAME}:${FINAL_IMAGE_TAG}"

            # 1. 로그인
            echo "Login to $REG_HOST as $REG_USER"
            sudo buildah login -u "$REG_USER" -p "$REG_PASS" "$REG_HOST"

            # 2. 빌드
            sudo buildah bud --storage-driver vfs --isolation chroot --platform "linux/amd64" -t "${IMAGE_REF}" .
            # 3. 푸시
            sudo buildah push --storage-driver vfs "${IMAGE_REF}"
            # 4. 정리
            sudo buildah rmi -a || true
          '''
        }
      }
    }

    // GitOps 업데이트 (ArgoCD CD 트리거) ────────────────
    // kustomize/overlays/dev 이미지 태그 수정 후 gitops 브랜치에 push
    stage('GitOps Update') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: "${GIT_ID}",
          usernameVariable: 'GIT_USER',
          passwordVariable: 'GIT_PASS'
        )]) {
          script {
            env.REPO_PATH = env.GIT_URL.replaceFirst(/^https?:\/\//, '')
          }
          sh '''
            set -eux
            git config --global user.name  "skala-gitops"
            git config --global user.email "skala@skala-ai.com"
            git config --global --add safe.directory '*'
            git remote set-url origin "https://${GIT_USER}:${GIT_PASS}@${REPO_PATH}"

            IMAGE_BASE="${IMAGE_REGISTRY_URL}/${IMAGE_REGISTRY_PROJECT}/${IMAGE_NAME}"

            # 1. 원격 gitops 브랜치가 있으면 그 히스토리를 이어받고, 없으면 현재 브랜치 기준으로 생성
            git fetch origin "${GITOPS_BRANCH}" || true
            if git rev-parse --verify "origin/${GITOPS_BRANCH}" >/dev/null 2>&1; then
              git checkout -B "${GITOPS_BRANCH}" "origin/${GITOPS_BRANCH}"
            else
              git checkout -B "${GITOPS_BRANCH}"
            fi

            # 2. kustomize/overlays/dev 이미지 태그 업데이트 (이후 명령은 원래 디렉토리에서 실행해야 하므로 서브셸 사용)
            (cd "${GITOPS_MANIFEST_DIR}" && kustomize edit set image "${IMAGE_BASE}=${IMAGE_BASE}:${FINAL_IMAGE_TAG}")

            # 3. 커밋 & 푸시 (원격 히스토리를 이어받았으므로 fast-forward push, --force 불필요)
            git add "${GITOPS_MANIFEST_DIR}/kustomization.yaml"
            git commit -m "[AUTO] image: ${IMAGE_NAME}:${FINAL_IMAGE_TAG}"
            git push origin "${GITOPS_BRANCH}"
            echo "[DONE] gitops 브랜치 업데이트 완료: ${IMAGE_BASE}:${FINAL_IMAGE_TAG}"
          '''
        }
      }
    }

  } // stages

  post {
    always {
      deleteDir()  // 워크스페이스 정리 (git clone, target/, 빌드 아티팩트)
    }
  }
}

