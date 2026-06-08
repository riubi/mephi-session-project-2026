# Сборка:  docker build -t mephi-session .
# Запуск:   docker run --rm -p 8080:80 --privileged -e STUDENT_ID=M2551076 -v "$PWD/artifacts:/artifacts" mephi-session
FROM fedora:43

ENV STUDENT_ID=M2551076
ENV ARTIFACTS=/artifacts

COPY setup.sh /setup.sh
RUN chmod +x /setup.sh

VOLUME ["/artifacts"]
ENTRYPOINT ["/setup.sh"]
