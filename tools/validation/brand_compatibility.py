def measurement_input(data):
    if not isinstance(data.get("trials"), list):
        return data
    return {**data, "trials": [
        {**trial, "controller": "roo-industries" if trial.get("controller") == "roo" else trial.get("controller")}
        for trial in data.get("trials", [])
    ]}
