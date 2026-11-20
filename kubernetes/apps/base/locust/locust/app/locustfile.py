# The load Locust puts on its target: each user it runs asks for the target's page, /, then waits one
# to three seconds and asks again. The target is the host the master hands the workers, LOCUST_TARGET
# in ks.yaml, unless the interface is given another one when a test starts. To change the load, change
# this file in a pull request: kustomize makes a new ConfigMap of it, and every pod of Locust restarts
# on it (docs/kubernetes.md, Locust).
from locust import HttpUser, between, task


class PageUser(HttpUser):
    wait_time = between(1, 3)

    @task
    def page(self):
        self.client.get("/")
