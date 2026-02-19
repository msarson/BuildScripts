pipeline {
    agent {
        node {
            label ''
            customWorkspace 'F:\\jenkins-workspaces\\AccuraBuild-SQL'
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
                        if (Test-Path "genfiles\\sqlsource") {
                            Remove-Item "genfiles\\sqlsource" -Recurse -Force
                            Write-Host "Removed genfiles/sqlsource/"
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

        stage('Build SQL') {
            steps {
                echo 'Starting Accura SQL build...'

                dir('Accura') {
                    powershell '''
                        C:\\BuildScripts\\build.ps1 -Mode SQL -ImportApps -GenerateBuildAll -SkipGitOperations -DebugBuild
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
