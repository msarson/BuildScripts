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
                echo 'Starting Accura TPS build...'

                dir('Accura') {
                    powershell '''
                        C:\\BuildScripts\\build.ps1 -Mode TPS -ImportApps -GenerateBuildAll -SkipGitOperations
                    '''
                }

                echo 'Build completed'
            }
        }
    }

    post {
        success {
            echo 'Build succeeded!'
        }
        failure {
            echo 'Build failed - check logs above'
        }
    }
}
