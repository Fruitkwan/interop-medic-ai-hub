# Overridden by docker-compose (IRIS_IMAGE). The default runs the mock-only build without AI Hub.
ARG IMAGE=intersystemsdc/iris-community:2026.2-zpm
FROM $IMAGE

WORKDIR /home/irisowner/medic
COPY --chown=irisowner:irisowner src src
COPY --chown=irisowner:irisowner src-aihub src-aihub
COPY --chown=irisowner:irisowner iris.script iris.script

# iris session does not pass compile errors through as an exit code, so fail the build on any "ERROR" line.
RUN iris start IRIS \
 && iris session IRIS < iris.script | tee /tmp/medic-build.log \
 && iris stop IRIS quietly \
 && ! grep -E "^ERROR|ERROR #" /tmp/medic-build.log
