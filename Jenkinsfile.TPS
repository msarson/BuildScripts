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
                    git branch: 'v640_Build7',
                        credentialsId: 'github-ssh',
                        url: 'git@github.com:accuramis/accura.git'
                }

                dir('Clarion') {
                    git branch: 'TPS',
                        credentialsId: 'github-ssh',
                        url: 'git@github.com:accuramis/Clarion10.git'
                }

                echo 'Repositories checked out successfully'
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
                            C:\\BuildScripts\\build.ps1 -Mode TPS -ImportApps -GenerateBuildAll -SkipGitOperations -DebugBuild
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
