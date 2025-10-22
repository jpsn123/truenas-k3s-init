FROM releases-docker.jfrog.io/jfrog/artifactory-pro:7.104.13
USER root
ADD --chmod=777 dist /opt/jfrog/artifactory/app/frontend/bin/client/dist
ADD --chmod=777 artifactory-addons-manager-*.jar /opt/jfrog/artifactory/app/artifactory/tomcat/webapps/artifactory/WEB-INF/lib
ADD --chmod=777 license-manager-*.jar /opt/jfrog/artifactory/app/access/tomcat/webapps/access/WEB-INF/lib
RUN sed -i 's|<title>JFrog</title>|<title>Jutze Artifact</title>|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/index.html && \
    sed -i 's|Welcome to JFrog|Welcome to Jutze Artifact Platform|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/js/loginExtra.*.js && \
    sed -i 's|Welcome to JFrog|Welcome to Jutze Artifact Platform|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/js/login.*.js && \
    sed -i 's|the JFrog Platform!|Jutze Artifact Platform!|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/js/chunk-*.js && \
    sed -i 's|Welcome to JFrog Container Registry|Welcome to Jutze Container Registry|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/js/chunk-*.js && \
    sed -i 's|Welcome to JFrog Container Registry|Welcome to Jutze Container Registry|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/js/appLayout.*.js && \
    sed -i 's|Welcome to JFrog|Welcome to Jutze Artifact Platform|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/js/app.*.js && \
    sed -i 's|"JFrog"|"Jutze Artifact"|g' /opt/jfrog/artifactory/app/frontend/bin/client/dist/js/app.*.js && \
    mv /opt/jfrog/artifactory/app/frontend/bin/client/dist/img/*.00000000.svg /tmp/ && \
    mv /tmp/jfrog-platform.00000000.svg $(find /opt/jfrog/artifactory/app/frontend/bin/client/dist/img/ -name "jfrog-platform.*.svg") && \
    mv /tmp/jfrog.00000000.svg $(find /opt/jfrog/artifactory/app/frontend/bin/client/dist/img/ -name "jfrog.*.svg") && \
    mv /tmp/login_logo.00000000.svg $(find /opt/jfrog/artifactory/app/frontend/bin/client/dist/img/ -name "login_logo.*.svg") && \
    mv /tmp/login_side.00000000.svg $(find /opt/jfrog/artifactory/app/frontend/bin/client/dist/img/ -name "login_side.*.svg") && \
    mv /tmp/logo.00000000.svg $(find /opt/jfrog/artifactory/app/frontend/bin/client/dist/img/ -name "logo.*.svg")
USER artifactory