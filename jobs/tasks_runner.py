import functools
import shutil
import site
import os
import pipes
import subprocess
import sys
import logging


try:
    from gdw_engine.bigquery_utils import SchemaUpdate
    from gdw_engine.loader import Bootstrapper, TableLoader, FileDataLoader
    from gdw_engine.quality import QualityScan, DfComparator
    from gdw_engine.tools import (
        add_target_project,
        add_target_table,
        add_table_prefix,
        add_target_dataset,
        add_source_project,
        add_temp_gcs,
        add_materialization_dataset,
        add_sql_path,
        add_expiration_time,
        add_source_dataset,
        add_source_table,
        add_where_clause,
        add_base_table_full_id,
        add_compare_table_full_id,
        add_target_table_full_id,
        add_join_columns,
        add_mapping_columns,
        add_more_filters,
        add_base_partition_field,
        add_base_partition_min,
        add_base_partition_max,
        add_base_clusters,
        add_compare_partition_field,
        add_compare_partition_min,
        add_compare_partition_max,
        add_compare_clusters,
        extract_zip
    )
except ImportError:
    pass


_logger: logging.Logger = logging.getLogger(__name__)


def depend_on(binaries=[], envs=[]):
    """ensure functions are called with the relevant binaries and environment variables set."""

    def decorator_depend_on(func):
        @functools.wraps(func)
        def wrapper_depend_on(*args, **kwargs):
            """allow prompt to set variables interactively."""

            missing_binaries = []

            for binary in binaries:
                if shutil.which(binary) is None:
                    missing_binaries.append(binary)
            missing_envs = []
            for env in envs:
                if not os.environ.get(env):
                    missing_envs.append(env)
            if missing_binaries or missing_envs:
                _logger.error(f'Exiting due to missing dependencies for "{func.__name__}"')
                _logger.error(f"- Binaries: {missing_binaries}")
                _logger.error(f"- Env vars: {missing_envs}")
                sys.exit(1)
            else:
                return func(*args, **kwargs)
        return wrapper_depend_on
    return decorator_depend_on


def _run(
        cmd, detach=False,
        log_command=True,
        error_callback=None,
        exit_on_error=True,
        **kwargs
) -> str:
    """Run a subcommand and exit if it fails."""

    if kwargs.get("capture_output", None):
        del kwargs["capture_output"]
        kwargs["stdout"] = kwargs["stderr"] = subprocess.PIPE

    if log_command:
        _logger.info(" ".join(map(pipes.quote, cmd)))

    if detach:
        with open(os.devnull, 'r+b', 0) as DEVNULL:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
        return proc
    else:
        proc = subprocess.run(cmd, **kwargs)

    if proc.returncode != 0:
        _logger.error("`{}` errored ({})".format(" ".join(map(pipes.quote, cmd)), proc.returncode))
        if proc.stderr:
            _logger.error(proc.stderr.decode("utf-8").strip())
        if error_callback:
            error_callback()
        if exit_on_error:
            sys.exit(proc.returncode)

    if proc.stdout:
        return proc.stdout.decode("utf-8").strip()
    return ""


def _str_to_list_tuples(s):
    return eval("%s" % s)


@depend_on(binaries=["pip"], envs=[])
def configure_cluster():
    """configure dataproc cluster w/ initial actions."""

    _logger.debug('Dataproc configuration started ...')
    _logger.debug(os.listdir("./"))
    available_wheels = [file for file in os.listdir("./") if file.endswith(".whl")]
    available_wheels.sort()
    wheel_file = available_wheels[-1]
    _run(cmd=["python", "-V"])
    _run(cmd=["pip", "-V"])
    _run(cmd=["pip", "install", "-r", "requirements/requirements.txt"])

    _logger.debug("installing with wheel file : {}".format(wheel_file))
    _run(cmd=["pip", "install", os.path.join("./", wheel_file), "--upgrade"])
    _logger.info('Dataproc initialized successfully !')

    try:
        reload(site)  # Python 2.7
    except NameError:
        try:
            from importlib import reload  # Python 3.4+
            reload(site)

        except ImportError:
            from imp import reload  # Python 3.0 - 3.3
            reload(site)

    except Exception as e:
        _logger.error('Error during Dataproc initialization !')
        raise e


if __name__ == "__main__":

    task = sys.argv[1]
    _logger.debug("task to run {}".format(task))
    if task == "configure":
        configure_cluster()
    else:
        _run(cmd=["ingestor", *sys.argv[1:]])
