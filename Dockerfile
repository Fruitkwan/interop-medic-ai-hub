# Overridden by docker-compose (IRIS_IMAGE). The default runs the mock-only build without AI Hub.
ARG IMAGE=intersystemsdc/iris-community:2026.2-zpm
FROM $IMAGE

WORKDIR /home/irisowner/medic
COPY --chown=irisowner:irisowner src src
COPY --chown=irisowner:irisowner iris.script iris.script

RUN iris start IRIS \
 && iris session IRIS < iris.script \
 && iris stop IRIS quietly
