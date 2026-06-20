pipeline {
    agent {
        node {
            label ''
            customWorkspace 'F:\\jenkins-workspaces\\AccuraBuild'
        }
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 2, unit: 'HOURS')
        // Only one build of this pipeline at a time. All builds share a single
        // customWorkspace, so a second concurrent build would git reset/clean the
        // tree the first is still compiling. Extra triggers queue until the current
        // build finishes (Jenkins coalesces multiple queued triggers into one).
        disableConcurrentBuilds()
    }

    triggers {
        // Check for changes every hour
        pollSCM('H * * * *')
    }

    stages {
        stage('Notify Started') {
            steps {
                emailext subject: "🔨 Accura TPS Build #${BUILD_NUMBER} - Started",
                         body: "Build #${BUILD_NUMBER} has started.\n\nView progress: ${BUILD_URL}console",
                         to: 'mark@marksarson.com'
            }
        }

        stage('Checkout Repositories') {
            steps {
                echo 'Checking out Accura and Clarion repositories...'

                dir('Accura') {
                    // Initial checkout - also fetches all remote-tracking branches
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
                }

                dir('Clarion') {
                    git branch: 'TPS',
                        credentialsId: 'github-ssh',
                        url: 'git@github.com:accuramis/Clarion10.git'
                }

                echo 'Repositories checked out successfully'
            }
        }

        stage('Checkout Build Scripts') {
            steps {
                echo 'Checking out BuildScripts (pipeline scripts) from repo...'
                // Run the pipeline scripts from a per-workspace checkout of the public
                // BuildScripts repo rather than the local C:\BuildScripts disk copy, so
                // what runs always matches a committed revision (no live-disk drift).
                dir('BuildScripts') {
                    git branch: 'master',
                        url: 'https://github.com/msarson/BuildScripts.git'
                }
            }
        }

        stage('Clean Build Artifacts') {
            when {
                expression { currentBuild.number > 1 }
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
            steps {
                lock('clarion-generator') {
                    echo 'Acquired Clarion generator lock - starting Accura TPS build...'

                    dir('Accura') {
                        powershell '''
                            & "$env:WORKSPACE\\BuildScripts\\build.ps1" -Mode TPS -ImportApps -GenerateBuildAll -SkipGitOperations -DebugBuild -ClarionPath "..\\Clarion"
                        '''
                    }

                    echo 'Build completed'
                }
            }
        }
    }

    post {
        success {
            emailext subject: "✅ Accura TPS Build #${BUILD_NUMBER} - Success",
                     body: "Build #${BUILD_NUMBER} completed successfully.\n\nView: ${BUILD_URL}",
                     to: 'mark@marksarson.com'
        }
        failure {
            emailext subject: "❌ Accura TPS Build #${BUILD_NUMBER} - FAILED",
                     body: "Build #${BUILD_NUMBER} failed.\n\nView logs: ${BUILD_URL}console",
                     attachmentsPattern: 'Accura/build-output/failed/*.log',
                     to: 'mark@marksarson.com'
        }
        fixed {
            emailext subject: "✅ Accura TPS Build #${BUILD_NUMBER} - Back to Normal",
                     body: "Build #${BUILD_NUMBER} is back to normal after a previous failure.\n\nView: ${BUILD_URL}",
                     to: 'mark@marksarson.com'
        }
    }
}
