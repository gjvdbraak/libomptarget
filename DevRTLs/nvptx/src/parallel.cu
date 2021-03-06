//===---- parallel.cu - NVPTX OpenMP parallel implementation ----- CUDA -*-===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// Parallel implemention in the GPU. Here is the pattern:
//
//    while (not finished) {
//
//    if (master) {
//      sequential code, decide which par loop to do, or if finished
//     __kmpc_kernel_prepare_parallel() // exec by master only
//    }
//    syncthreads // A
//    __kmpc_kernel_parallel() // exec by all
//    if (this thread is included in the parallel) {
//      switch () for all parallel loops
//      __kmpc_kernel_end_parallel() // exec only by threads in parallel
//    }
//
//
//    The reason we don't exec end_parallel for the threads not included
//    in the parallel loop is that for each barrier in the parallel
//    region, these non-included threads will cycle through the
//    syncthread A. Thus they must preserve their current threadId that
//    is larger than thread in team.
//
//    To make a long story short...
//
//===----------------------------------------------------------------------===//

#include "omptarget-nvptx.h"

////////////////////////////////////////////////////////////////////////////////
// support for parallel that goes parallel (1 static level only)
////////////////////////////////////////////////////////////////////////////////

// return number of threads that participate to parallel
EXTERN int __kmpc_kernel_prepare_parallel(int numThreads, int numLanes)
{
  PRINT0(LD_IO , "call to __kmpc_kernel_init_parallel\n");
  int globalThreadId = GetGlobalThreadId();
  omptarget_nvptx_TaskDescr *currTaskDescr = 
    omptarget_nvptx_threadPrivateContext.GetTopLevelTaskDescr(globalThreadId);
  ASSERT0(LT_FUSSY, currTaskDescr, "expected a top task descr");
  if (currTaskDescr->InParallelRegion()) {
    PRINT0(LD_PAR, "already in parallel: go seq\n");

    // todo: support nested parallelism
    return FALSE;
  }
  uint16_t tnum = omptarget_nvptx_threadPrivateContext.NumThreadsForNextParallel(globalThreadId);
  if (tnum != 0) {
    PRINT(LD_PAR, "parallel region pushed a request of %d threads\n", tnum);
    // reset request
    omptarget_nvptx_threadPrivateContext.NumThreadsForNextParallel(globalThreadId) = 0;
  } else {
    // get default
    tnum = currTaskDescr->NThreads();
    PRINT(LD_PAR, "parallel region uses default number of threads %d\n", tnum);
  }
  int tmax = GetNumberOfProcsInTeam();
  if (tnum > tmax) {
    PRINT(LD_PAR, 
      "parallel region use more threads %d than avail; truncate to %d\n", 
       tnum, tmax);
    tnum = tmax;
  }
  ASSERT(LT_FUSSY, tnum > 0, "bad thread request of %d threads", tnum);
  ASSERT0(LT_FUSSY, GetThreadIdInBlock() == TEAM_MASTER, "only team master can create parallel");
  // set number of threads on work descriptor  
  omptarget_nvptx_WorkDescr & workDescr = getMyWorkDescriptor(); 
  workDescr.WorkTaskDescr()->CopyToWorkDescr(currTaskDescr, tnum);
  // init counters (copy start to init)
  workDescr.CounterGroup().Reset();
  return tnum;
}

// works only for active parallel looop...
EXTERN void __kmpc_kernel_parallel(int numLanes)
{
  PRINT0(LD_IO | LD_PAR, "call to __kmpc_kernel_parallel\n");
  // init work descriptor from workdesccr
  int globalThreadId = GetGlobalThreadId();
  omptarget_nvptx_TaskDescr *newTaskDescr = 
    omptarget_nvptx_threadPrivateContext.Level1TaskDescr(globalThreadId);
  omptarget_nvptx_WorkDescr & workDescr = getMyWorkDescriptor(); 
  ASSERT0(LT_FUSSY, newTaskDescr, "expected a task descr");
  newTaskDescr->CopyFromWorkDescr(workDescr.WorkTaskDescr());
  // install new top descriptor
  omptarget_nvptx_threadPrivateContext.SetTopLevelTaskDescr(globalThreadId, newTaskDescr);
  // init private from int value
  workDescr.CounterGroup().Init(omptarget_nvptx_threadPrivateContext.Priv(globalThreadId));
  PRINT(LD_PAR, "thread will execute parallel region with id %d in a team of %d threads\n",
    newTaskDescr->ThreadId(), newTaskDescr->NThreads());
}



EXTERN void __kmpc_kernel_end_parallel()
{
  PRINT0(LD_IO | LD_PAR, "call to __kmpc_kernel_end_parallel\n");
  // pop stack
  int globalThreadId = GetGlobalThreadId();
  omptarget_nvptx_TaskDescr *currTaskDescr = getMyTopTaskDescriptor(globalThreadId);
  omptarget_nvptx_threadPrivateContext.SetTopLevelTaskDescr(globalThreadId, 
    currTaskDescr->GetPrevTaskDescr());
}


////////////////////////////////////////////////////////////////////////////////
// support for parallel that goes sequential
////////////////////////////////////////////////////////////////////////////////

EXTERN void __kmpc_serialized_parallel(kmp_Indent *loc, uint32_t global_tid)
{
  PRINT0(LD_IO, "call to __kmpc_serialized_parallel\n");
  
  // assume this is only called for nested parallel
  int globalThreadId = GetGlobalThreadId();

  // unlike actual parallel, threads in the same team do not share
  // the workTaskDescr in this case and num threads is fixed to 1  
  
  // get current task
  omptarget_nvptx_TaskDescr *currTaskDescr = getMyTopTaskDescriptor(globalThreadId);

  // allocate new task descriptor and copy value from current one, set prev to it
  omptarget_nvptx_TaskDescr *newTaskDescr = (omptarget_nvptx_TaskDescr *) 
    SafeMalloc(sizeof(omptarget_nvptx_TaskDescr), (char *) "new seq parallel task");
  newTaskDescr->CopyParent(currTaskDescr);

  // tweak values for serialized parallel case:
  // - each thread becomes ID 0 in its serialized parallel, and
  // - there is only one thread per team
  newTaskDescr->ThreadId() = 0;
  newTaskDescr->ThreadsInTeam() = 1;
  
  // set new task descriptor as top
  omptarget_nvptx_threadPrivateContext.SetTopLevelTaskDescr(globalThreadId, newTaskDescr);
}

EXTERN void __kmpc_end_serialized_parallel(kmp_Indent *loc, uint32_t global_tid)
{
  PRINT0(LD_IO, "call to __kmpc_end_serialized_parallel\n");
  
  // pop stack
  int globalThreadId = GetGlobalThreadId();
  omptarget_nvptx_TaskDescr *currTaskDescr = getMyTopTaskDescriptor(globalThreadId);
  // set new top
  omptarget_nvptx_threadPrivateContext.SetTopLevelTaskDescr(globalThreadId, 
    currTaskDescr->GetPrevTaskDescr());
  // free
  SafeFree(currTaskDescr, (char *) "new seq parallel task");
}

////////////////////////////////////////////////////////////////////////////////
// push params
////////////////////////////////////////////////////////////////////////////////


EXTERN void __kmpc_push_num_threads (kmp_Indent * loc, int32_t gtid, 
  int32_t num_threads)
{
  PRINT(LD_IO, "call kmpc_push_num_threads %d\n", num_threads);
  // only the team master updates the state
  gtid = GetGlobalThreadId();
  omptarget_nvptx_threadPrivateContext.NumThreadsForNextParallel(gtid) = num_threads;	
}

// Do not do nothing: the host guarantees we started the requested number of
// teams and we only need inspection gridDim

EXTERN void __kmpc_push_num_teams (kmp_Indent * loc, int32_t gtid, 
  int32_t num_teams, int32_t thread_limit)
{
  PRINT(LD_IO, "call kmpc_push_num_teams %d\n", num_teams);
  ASSERT0(LT_FUSSY, FALSE, "should never have anything with new teams on device");
}

