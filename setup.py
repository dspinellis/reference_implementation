import setuptools

with open("README.md", "r") as fh:
    long_description = fh.read()

setuptools.setup(
    name="epidose",
    version="0.0.1",
    author="Diomidis Spinellis,EPFL",
    maintainer="Diomidis Spinellis",
    maintainer_email="dds@aueb.gr",
    description="Epidemic dosimeter based on DP3T",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/dspinellis/epidose",
    packages=setuptools.find_packages(),
    classifiers=[
        "Development Status :: 3 - Alpha",
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: Apache Software License"
        "Operating System :: OS Independent",
    ],
    python_requires=">=3.6",
    install_requires=[
        "flask",
        "flask_restful",
        "gunicorn",
        "pybluez",
        "pycryptodomex",
        "peewee",
        "requests",
        "RPi.GPIO",
        "scalable-cuckoo-filter",
    ],
    extras_require={
        "dev": ["black", "flake8", "pre-commit"],
        "test": ["pytest", "testfixtures"],
        "deploy": ["make-deb"],
    },
    scripts=[
        "epidose/device/update_filter_d.sh",
        "epidose/device/upload_seeds_d.sh",
        "epidose/device/util.sh",
    ],
    # Could also support entry_points console_scripts, but they are
    # not supported by the current version of make_deb
    # See https://github.com/nylas/make-deb/pull/11
)
