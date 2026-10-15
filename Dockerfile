# Community image for now. Swap for the AI Hub Early Access image once licensing is confirmed.
ARG IMAGE=intersystemsdc/iris-community:2026.2-zpm
FROM $IMAGE

WORKDIR /home/irisowner/medic
COPY --chown=irisowner:irisowner src src
COPY --chown=irisowner:irisowner iris.script iris.script

RUN iris start IRIS \
 && iris session IRIS < iris.script \
 && iris stop IRIS quietly
