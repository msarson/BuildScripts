pipeline {
    agent {
        node {
            label ''
            customWorkspace 'F:\\jenkins-workspaces\\AccuraBuild'
        }
    }

    options {
        // Hourly heartbeat (see triggers) means most builds are cheap "no change"
        // skips, so keep plenty of history by days as well as count, otherwise real
        // build logs get rotated out within hours.
        buildDiscarder(logRotator(daysToKeepStr: '21', numToKeepStr: '250'))
        timeout(time: 2, unit: 'HOURS')
        // Only one build of this pipeline at a time. All builds share a single
        // customWorkspace, so a second concurrent build would git reset/clean the
        // tree the first is still compiling. Extra triggers queue until the current
        // build finishes (Jenkins coalesces multiple queued triggers into one).
        disableConcurrentBuilds()
    }

    triggers {
        // Hourly heartbeat. Fires unconditionally; the 'Determine Build Branch' stage
        // decides whether there is actually new work and skips the heavy Clarion build
        // when the latest branch tip has already been built. We use a timer rather than
        // pollSCM because the build always targets the *latest* v###_Build# branch
        // (picked by commit date): a branch-wildcard pollSCM matches ~70 stale build
        // branches that look "never built" and so retriggers every hour regardless,
        // while pinning pollSCM to a single branch misses brand-new branches.
        cron('H * * * *')
    }

    stages {
        stage('Determine Build Branch') {
            steps {
                echo 'Checking out Accura and selecting the latest build branch...'

                dir('Accura') {
                    // Fetch all remote-tracking branches (default refspec) so the
                    // latest-branch selection below can see every v###_Build#.
                    git branch: 'master',
                        credentialsId: 'github-ssh',
                        url: 'git@github.com:accuramis/accura.git'

                    // Build server: never retain local workspace changes. Discard all
                    // tracked modifications and remove untracked files so a checkout or
                    // pull can never fail on a dirty tree. genfiles/* is gitignored, so
                    // incremental build artifacts (e.g. classes.lib) are preserved
                    // (no -x); the dedicated Clean stage manages build outputs.
                    powershell '''
                        git reset --hard
                        git clean -ffd
                    '''

                    // Trevor cuts new v###_Build# branches often, so always build the
                    // most recently committed one instead of a hardcoded branch.
                    script {
                        env.ACCURA_BRANCH = powershell(returnStdout: true, script: '''
                            $refs = @(git for-each-ref --sort=-committerdate --format="%(refname:short)" "refs/remotes/origin/v*_Build*")
                            if ($refs.Count -eq 0) { Write-Error "No v###_Build# branches found on accura remote"; exit 1 }
                            Write-Output ($refs[0] -replace "^origin/", "")
                            exit 0
                        ''').trim()
                    }
                    echo "Latest Accura branch (by commit date): ${env.ACCURA_BRANCH}"

                    // A bare 'git checkout <branch>' only switches to a pre-existing
                    // local branch and does NOT advance it to the fetched origin tip,
                    // so the workspace can build stale source (was 20 commits behind).
                    // -f -B forces the local branch to point at origin/<branch>,
                    // discarding any local workspace changes, so we always build HEAD.
                    powershell "git checkout -f -B ${env.ACCURA_BRANCH} origin/${env.ACCURA_BRANCH}"

                    // Decide whether there is anything new to build. Compare the tip we
                    // are about to build against the SHA recorded by the last build
                    // attempt (stored in the workspace ROOT - outside Accura/ so
                    // 'git clean' never removes it). If unchanged, skip the expensive
                    // Clarion generate+compile. We key on SHA, not commit age, so a
                    // newly pushed branch whose tip commit happens to be hours old is
                    // still built, and a single commit is never rebuilt twice.
                    script {
                        env.ACCURA_TIP = powershell(returnStdout: true, script: 'git rev-parse HEAD').trim()
                        def marker = "${env.WORKSPACE}\\.tps-last-built-sha"
                        def lastBuilt = powershell(returnStdout: true, script: """
                            if (Test-Path '${marker}') { (Get-Content '${marker}' -Raw).Trim() } else { '' }
                        """).trim()
                        if (env.ACCURA_TIP == lastBuilt) {
                            env.SHOULD_BUILD = 'false'
                            echo "No new commits on ${env.ACCURA_BRANCH} (tip ${env.ACCURA_TIP.take(10)} already built) - skipping heavy build."
                            currentBuild.result = 'NOT_BUILT'
                            currentBuild.description = "No change: ${env.ACCURA_BRANCH} @ ${env.ACCURA_TIP.take(10)}"
                        } else {
                            env.SHOULD_BUILD = 'true'
                            currentBuild.description = "Build ${env.ACCURA_BRANCH} @ ${env.ACCURA_TIP.take(10)}"
                        }
                    }
                }
            }
        }

        stage('Notify Started') {
            when { expression { env.SHOULD_BUILD == 'true' } }
            steps {
                emailext subject: "🔨 Accura TPS Build #${BUILD_NUMBER} - Started (${env.ACCURA_BRANCH})",
                         body: "Build #${BUILD_NUMBER} has started on ${env.ACCURA_BRANCH}.\n\nView progress: ${BUILD_URL}console",
                         to: 'mark@marksarson.com'
            }
        }

        stage('Checkout Clarion & Build Scripts') {
            when { expression { env.SHOULD_BUILD == 'true' } }
            steps {
                echo 'Checking out Clarion and BuildScripts...'

                dir('Clarion') {
                    git branch: 'TPS',
                        credentialsId: 'github-ssh',
                        url: 'git@github.com:accuramis/Clarion10.git'
                }

                // Run the pipeline scripts from a per-workspace checkout of the public
                // BuildScripts repo rather than the local C:\BuildScripts disk copy, so
                // what runs always matches a committed revision (no live-disk drift).
                dir('BuildScripts') {
                    git branch: 'master',
                        url: 'https://github.com/msarson/BuildScripts.git'
                }

                echo 'Repositories checked out successfully'
            }
        }

        stage('Clean Build Artifacts') {
            when {
                allOf {
                    expression { env.SHOULD_BUILD == 'true' }
                    expression { currentBuild.number > 1 }
                }
            }
            steps {
                echo 'Cleaning generated source and build-output (incremental build)...'

                dir('Accura') {
                    powershell '''
                        if (Test-Path "genfiles\\source") {
                            Remove-Item "genfiles\\source" -Recurse -Force
                            Write-Host "Removed genfiles/source/"
                        }
                        if (Test-Path "build-output") {
                            Remove-Item "build-output" -Recurse -Force
                            Write-Host "Removed build-output/"
                        }
                    '''
                }

                echo 'Clean completed'
            }
        }

        stage('Build TPS') {
            when { expression { env.SHOULD_BUILD == 'true' } }
            steps {
                lock('clarion-generator') {
                    echo 'Acquired Clarion generator lock - starting Accura TPS build...'

                    // Materialise the licensed ClarionProperties.xml (Clarion serial)
                    // from the Jenkins Secret file credential; build.ps1 reads its path
                    // via $env:CLARION_CONFIG_XML. Keeps the serial out of the repo/logs.
                    withCredentials([file(credentialsId: 'clarion-license-config', variable: 'CLARION_CONFIG_XML')]) {
                        dir('Accura') {
                            powershell '''
                                & "$env:WORKSPACE\\BuildScripts\\build.ps1" -Mode TPS -ImportApps -GenerateBuildAll -SkipGitOperations -DebugBuild -ClarionPath "..\\Clarion"
                            '''
                        }
                    }

                    echo 'Build completed'
                }
            }
        }
    }

    post {
        always {
            // Record the tip we just attempted (whether it passed or failed) so the
            // same commit is not rebuilt on the next hourly heartbeat. A later push
            // (new SHA) or a newer branch will differ and trigger a fresh build. We
            // deliberately do NOT retry a failed commit every hour - a fix is a new
            // commit, which supersedes this marker.
            script {
                if (env.SHOULD_BUILD == 'true' && env.ACCURA_TIP?.trim()) {
                    def marker = "${env.WORKSPACE}\\.tps-last-built-sha"
                    powershell "Set-Content -Path '${marker}' -Value '${env.ACCURA_TIP}' -NoNewline"
                }
            }
        }
        success {
            script {
                if (env.SHOULD_BUILD == 'true') {
                    emailext subject: "✅ Accura TPS Build #${BUILD_NUMBER} - Success (${env.ACCURA_BRANCH})",
                             body: "Build #${BUILD_NUMBER} completed successfully on ${env.ACCURA_BRANCH}.\n\nView: ${BUILD_URL}",
                             to: 'mark@marksarson.com'
                }
            }
        }
        failure {
            script {
                if (env.SHOULD_BUILD == 'true') {
                    emailext subject: "❌ Accura TPS Build #${BUILD_NUMBER} - FAILED (${env.ACCURA_BRANCH})",
                             body: "Build #${BUILD_NUMBER} failed on ${env.ACCURA_BRANCH}.\n\nView logs: ${BUILD_URL}console",
                             attachmentsPattern: 'Accura/build-output/failed/*.log',
                             to: 'mark@marksarson.com'
                }
            }
        }
        fixed {
            script {
                if (env.SHOULD_BUILD == 'true') {
                    emailext subject: "✅ Accura TPS Build #${BUILD_NUMBER} - Back to Normal (${env.ACCURA_BRANCH})",
                             body: "Build #${BUILD_NUMBER} is back to normal after a previous failure.\n\nView: ${BUILD_URL}",
                             to: 'mark@marksarson.com'
                }
            }
        }
    }
}
